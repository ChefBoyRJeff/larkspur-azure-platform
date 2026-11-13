// Container Apps environment in vnet-lark, plus two M4a workloads that prove the platform before real code runs on it:
//   ca-lark-hello      Microsoft's public quickstart image with external ingress: proves inbound from the internet
//                      and outbound (the image has to be pulled from Microsoft's registry through a private subnet).
//   job-lark-dnscheck  one-shot job that resolves the SQL and Key Vault names from INSIDE the VNet and prints the
//                      addresses: proves private DNS end to end (expect 10.60.1.x, not public IPs).
//
// Environment decisions:
// - Workload profiles environment with only the Consumption profile: scale to zero, pay per use, free monthly grant.
//   No dedicated profiles and no environment private endpoint, so no "management hour" charge (M0 pricing).
// - External (internal: false): the tracking API is customer-facing. Inbound goes through the environment's public
//   IP; the data tier stays private.
// - infrastructureResourceGroup: the platform creates a managed group with a Standard Load Balancer and public IPs,
//   which are billed separately. Naming it rg-lark-app-infra (instead of the default ME_...) lets the budget filter
//   on it. It's deleted automatically with the environment.
// - Logs go to the persistent workspace in rg-lark-data so they survive the session teardown.
targetScope = 'resourceGroup'

@description('Region')
param location string

@description('Standard Larkspur tags')
param tags object

@description('Resource ID of snet-aca (delegated to Microsoft.App/environments)')
param acaSubnetId string

@description('Name for the platform-managed infrastructure resource group (must not already exist)')
param infrastructureResourceGroupName string

@description('Resource group holding the Log Analytics workspace')
param dataResourceGroupName string

@description('Log Analytics workspace name')
param logAnalyticsWorkspaceName string

@description('SQL server FQDN to resolve from inside the VNet')
param sqlServerFqdn string

@description('Key Vault FQDN to resolve from inside the VNet')
param keyVaultFqdn string

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: logAnalyticsWorkspaceName
  scope: resourceGroup(dataResourceGroupName)
}

resource environment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: 'cae-lark'
  location: location
  tags: tags
  properties: {
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
    vnetConfiguration: {
      infrastructureSubnetId: acaSubnetId
      internal: false
    }
    infrastructureResourceGroup: infrastructureResourceGroupName
    zoneRedundant: false
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: workspace.properties.customerId
        sharedKey: workspace.listKeys().primarySharedKey
      }
    }
  }
}

resource hello 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'ca-lark-hello'
  location: location
  tags: tags
  properties: {
    environmentId: environment.id
    workloadProfileName: 'Consumption'
    configuration: {
      ingress: {
        external: true
        targetPort: 80
        transport: 'auto'
        allowInsecure: false
      }
    }
    template: {
      containers: [
        {
          name: 'hello'
          image: 'mcr.microsoft.com/k8se/quickstart:latest'
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
        }
      ]
      scale: {
        minReplicas: 0
        maxReplicas: 1
      }
    }
  }
}

resource dnsCheck 'Microsoft.App/jobs@2024-03-01' = {
  name: 'job-lark-dnscheck'
  location: location
  tags: tags
  properties: {
    environmentId: environment.id
    workloadProfileName: 'Consumption'
    configuration: {
      triggerType: 'Manual'
      replicaTimeout: 120
      replicaRetryLimit: 0
      manualTriggerConfig: {
        parallelism: 1
        replicaCompletionCount: 1
      }
    }
    template: {
      containers: [
        {
          name: 'dnscheck'
          image: 'mcr.microsoft.com/azurelinux/base/python:3.12'
          command: [
            'python3'
            '-c'
            'import socket; [print("LARK-DNS", n, "->", socket.gethostbyname(n)) for n in ["${sqlServerFqdn}", "${keyVaultFqdn}"]]'
          ]
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
        }
      ]
    }
  }
}

output environmentName string = environment.name
output helloFqdn string = hello.properties.configuration.ingress.fqdn
output dnsCheckJobName string = dnsCheck.name
