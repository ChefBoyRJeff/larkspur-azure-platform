// Container Apps environment in vnet-lark and the Larkspur workloads that run in it:
//   ca-lark-tracking-api  the shipment-tracking API (external ingress), identity id-lark-tracking-api
//   job-lark-migrate      one-shot migration job (schema, seed, app database user, generated secret),
//                         identity id-lark-migrator, same image as the API
//   job-lark-dnscheck     one-shot check that resolves the data-tier names from inside the VNet (M4a)
//
// Environment decisions (M4a):
// - Workload profiles environment with only the Consumption profile: scale to zero, pay per use, free monthly grant.
//   No dedicated profiles and no environment private endpoint, so no "management hour" charge (M0 pricing).
// - External (internal: false): the tracking API is customer-facing; the data tier stays private.
// - infrastructureResourceGroup = rg-lark-app-infra so the budget covers the load balancer + public IPs the platform
//   creates. It's deleted automatically with the environment.
// - Logs go to the persistent workspace in rg-lark-data so they survive the session teardown.
// - peerAuthentication / peerTrafficConfiguration declared at Azure's defaults (off), so what-if shows no drift.
//   Both apply to app-to-app traffic inside the environment; this design has one app, so there's nothing to encrypt
//   between apps yet (noted as a production improvement).
targetScope = 'resourceGroup'

@description('Region')
param location string

@description('Standard Larkspur tags')
param tags object

@description('Resource ID of snet-aca (delegated to Microsoft.App/environments)')
param acaSubnetId string

@description('Name for the platform-managed infrastructure resource group (must not already exist)')
param infrastructureResourceGroupName string

@description('Resource group holding the Log Analytics workspace and the managed identities')
param dataResourceGroupName string

@description('Log Analytics workspace name')
param logAnalyticsWorkspaceName string

@description('SQL server FQDN')
param sqlServerFqdn string

@description('SQL database name')
param sqlDatabaseName string

@description('Key Vault FQDN (no scheme)')
param keyVaultFqdn string

@description('Container image for the API and the migration job')
param containerImage string

@description('Name of the API\'s user-assigned identity (in the data resource group)')
param appIdentityName string

@description('Name of the migration job\'s user-assigned identity (in the data resource group)')
param migratorIdentityName string

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: logAnalyticsWorkspaceName
  scope: resourceGroup(dataResourceGroupName)
}

resource appIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: appIdentityName
  scope: resourceGroup(dataResourceGroupName)
}

resource migratorIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: migratorIdentityName
  scope: resourceGroup(dataResourceGroupName)
}

var keyVaultUri = 'https://${keyVaultFqdn}/'

// Settings shared by the API and the migration job. Nothing here is secret: both authenticate with managed identities.
var commonEnv = [
  {
    name: 'SQL_SERVER'
    value: sqlServerFqdn
  }
  {
    name: 'SQL_DATABASE'
    value: sqlDatabaseName
  }
  {
    name: 'KEY_VAULT_URI'
    value: keyVaultUri
  }
  {
    name: 'CARRIER_SECRET_NAME'
    value: 'carrier-api-key'
  }
]

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
    peerAuthentication: {
      mtls: {
        enabled: false
      }
    }
    peerTrafficConfiguration: {
      encryption: {
        enabled: false
      }
    }
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: workspace.properties.customerId
        sharedKey: workspace.listKeys().primarySharedKey
      }
    }
  }
}

resource trackingApi 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'ca-lark-tracking-api'
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${appIdentity.id}': {}
    }
  }
  properties: {
    environmentId: environment.id
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      maxInactiveRevisions: 100
      ingress: {
        external: true
        targetPort: 8000
        transport: 'auto'
        allowInsecure: false
        traffic: [
          {
            latestRevision: true
            weight: 100
          }
        ]
      }
    }
    template: {
      containers: [
        {
          name: 'tracking-api'
          image: containerImage
          env: concat(commonEnv, [
            {
              name: 'AZURE_CLIENT_ID'
              value: appIdentity.properties.clientId
            }
          ])
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          // Probes hit /healthz (process only), never /readyz: probing the database would keep the free-tier database
          // from auto-pausing and would fail every time it resumes from a pause.
          probes: [
            {
              type: 'Liveness'
              httpGet: {
                path: '/healthz'
                port: 8000
              }
              periodSeconds: 30
            }
            {
              type: 'Readiness'
              httpGet: {
                path: '/healthz'
                port: 8000
              }
              periodSeconds: 10
            }
          ]
        }
      ]
      scale: {
        minReplicas: 0
        maxReplicas: 1
      }
    }
  }
}

resource migrateJob 'Microsoft.App/jobs@2024-03-01' = {
  name: 'job-lark-migrate'
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${migratorIdentity.id}': {}
    }
  }
  properties: {
    environmentId: environment.id
    workloadProfileName: 'Consumption'
    configuration: {
      triggerType: 'Manual'
      replicaTimeout: 600
      replicaRetryLimit: 0
      manualTriggerConfig: {
        parallelism: 1
        replicaCompletionCount: 1
      }
    }
    template: {
      containers: [
        {
          name: 'migrate'
          image: containerImage
          command: [
            'python'
            '-m'
            'larkspur.migrate'
          ]
          env: concat(commonEnv, [
            {
              name: 'AZURE_CLIENT_ID'
              value: migratorIdentity.properties.clientId
            }
            {
              name: 'APP_IDENTITY_NAME'
              value: appIdentity.name
            }
            {
              name: 'APP_IDENTITY_CLIENT_ID'
              value: appIdentity.properties.clientId
            }
          ])
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
        }
      ]
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
output apiFqdn string = trackingApi.properties.configuration.ingress.fqdn
output migrateJobName string = migrateJob.name
output dnsCheckJobName string = dnsCheck.name
