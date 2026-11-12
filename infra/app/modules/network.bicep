// vnet-lark with two subnets and their NSGs.
//
// snet-aca  -> Container Apps environment (delegated). Rules follow Microsoft's NSG table for workload-profiles
//              environments: load balancer probes, intra-subnet traffic, and HTTP/HTTPS for public clients.
// snet-pe   -> private endpoints for SQL (1433) and Key Vault (443). Only the app subnet may reach them.
//
// Both NSGs end with Deny-VNet-Inbound at 4000. Azure's default AllowVnetInBound (65000) would otherwise let
// anything in the VNet, and anything peered or connected over VPN later (depots), reach these subnets.
targetScope = 'resourceGroup'

@description('Region')
param location string

@description('Standard Larkspur tags')
param tags object

@description('VNet name')
param vnetName string

@description('VNet address space')
param vnetAddressPrefix string

@description('Container Apps subnet prefix')
param acaSubnetPrefix string

@description('Private endpoint subnet prefix')
param peSubnetPrefix string

resource nsgAca 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-lark-aca'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-AzureLoadBalancer-Probes'
        properties: {
          description: 'Azure Load Balancer health probes to the environment nodes'
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: acaSubnetPrefix
          destinationPortRange: '30000-32767'
        }
      }
      {
        name: 'Allow-Intra-Subnet'
        properties: {
          description: 'Container Apps infrastructure traffic between IPs in the environment subnet'
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: acaSubnetPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: acaSubnetPrefix
          destinationPortRange: '*'
        }
      }
      {
        name: 'Allow-Web-From-Internet'
        properties: {
          description: 'Public shipment-tracking API: HTTP/HTTPS and the environment edge proxy ports'
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: acaSubnetPrefix
          destinationPortRanges: [
            '80'
            '443'
            '31080'
            '31443'
          ]
        }
      }
      {
        name: 'Deny-VNet-Inbound'
        properties: {
          description: 'Override the default AllowVnetInBound: nothing else in (or connected to) the VNet gets in'
          priority: 4000
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

resource nsgPe 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-lark-pe'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-SQL-From-App'
        properties: {
          description: 'tracking-api to the Azure SQL private endpoint'
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: acaSubnetPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: peSubnetPrefix
          destinationPortRange: '1433'
        }
      }
      {
        name: 'Allow-HTTPS-From-App'
        properties: {
          description: 'tracking-api to the Key Vault private endpoint'
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: acaSubnetPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: peSubnetPrefix
          destinationPortRange: '443'
        }
      }
      {
        name: 'Deny-VNet-Inbound'
        properties: {
          description: 'Override the default AllowVnetInBound: only the app subnet reaches the private endpoints'
          priority: 4000
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

// Subnets are declared inline (not as separate child resources) so a VNet redeploy never removes them.
resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    // Declared at the value Azure stores by default. Leaving it out made the post-deploy what-if report Modify on
    // every run (M2 drift check). 'Disabled' = no VNet-level private endpoint traffic policy, which is what we want:
    // NSG enforcement for private endpoints is controlled per subnet (snet-pe below).
    privateEndpointVNetPolicies: 'Disabled'
    subnets: [
      {
        name: 'snet-aca'
        properties: {
          addressPrefix: acaSubnetPrefix
          networkSecurityGroup: {
            id: nsgAca.id
          }
          delegations: [
            {
              name: 'Microsoft.App.environments'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
          // Private subnet: no implicit internet egress. The Container Apps environment brings its own managed
          // outbound path; M4 verifies the app can still pull its image and reach Entra ID.
          defaultOutboundAccess: false
        }
      }
      {
        name: 'snet-pe'
        properties: {
          addressPrefix: peSubnetPrefix
          networkSecurityGroup: {
            id: nsgPe.id
          }
          // Without this, NSG rules are NOT applied to traffic destined for private endpoints; the NSG would be
          // decoration. NetworkSecurityGroupEnabled turns on NSG enforcement only (route tables stay unaffected).
          privateEndpointNetworkPolicies: 'NetworkSecurityGroupEnabled'
          defaultOutboundAccess: false
        }
      }
    ]
  }
}

output vnetId string = vnet.id
output vnetName string = vnet.name
output acaSubnetId string = '${vnet.id}/subnets/snet-aca'
output peSubnetId string = '${vnet.id}/subnets/snet-pe'
