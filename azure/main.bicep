// Azure infrastructure for Vaultwarden
// Deploys: VNet, NSG, public IP (SSH only), NIC, B1ms VM with managed identity
// Cloudflare Tunnel means NO inbound 80/443 needed — NSG only allows SSH.

targetScope = 'resourceGroup'

@description('Azure region — defaults to resource group location')
param location string = resourceGroup().location

@description('Prefix for all resource names')
param namePrefix string = 'vaultwarden'

@description('VM administrator username')
param adminUsername string = 'azureuser'

@description('SSH public key for VM access (contents of ~/.ssh/id_rsa.pub or similar)')
param sshPublicKey string

@description('VM size. B1ms (1 vCPU, 2 GB) is the sweet spot for 1–5 users (~$14/mo). B1s (1 GB, ~$8/mo) works but is tighter.')
@allowed(['Standard_B1s', 'Standard_B1ms', 'Standard_B2s', 'Standard_B2ms'])
param vmSize string = 'Standard_B1ms'

@description('OS disk size in GB')
param osDiskSizeGB int = 30

@description('Your public IP to allow SSH from. Use * to allow all (not recommended).')
param allowSshFromIP string = '*'

@description('Cloud-init script (base64-encoded) run on first boot to install Docker etc.')
param cloudInitScript string = ''

// ── Networking ────────────────────────────────────────────────────────────────

resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: '${namePrefix}-vnet'
  location: location
  properties: {
    addressSpace: { addressPrefixes: ['10.0.0.0/16'] }
    subnets: [
      {
        name: 'default'
        properties: {
          addressPrefix: '10.0.1.0/24'
          networkSecurityGroup: { id: nsg.id }
        }
      }
    ]
  }
}

// NSG: allow SSH inbound only — Cloudflare Tunnel handles all Vaultwarden traffic
resource nsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: '${namePrefix}-nsg'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowSSH'
        properties: {
          priority: 1000
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: allowSshFromIP
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
          description: 'SSH management access — restrict to your IP in production'
        }
      }
      {
        name: 'DenyAllInbound'
        properties: {
          priority: 4096
          protocol: '*'
          access: 'Deny'
          direction: 'Inbound'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
          description: 'Explicit deny-all — Vaultwarden is only reachable via Cloudflare Tunnel'
        }
      }
    ]
  }
}

// Static public IP — used only for SSH management, NOT for Vaultwarden
resource publicIp 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: '${namePrefix}-ip'
  location: location
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: '${namePrefix}-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: { id: vnet.properties.subnets[0].id }
          publicIPAddress: { id: publicIp.id }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

// ── Virtual Machine ───────────────────────────────────────────────────────────

resource vm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: '${namePrefix}-vm'
  location: location
  // System-assigned managed identity — used to authenticate to Azure Key Vault
  // without storing credentials anywhere on the VM
  identity: { type: 'SystemAssigned' }
  properties: {
    hardwareProfile: { vmSize: vmSize }
    osProfile: {
      computerName: '${namePrefix}-vm'
      adminUsername: adminUsername
      // Password auth disabled — SSH key only
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
        // Automatically apply OS security patches
        patchSettings: {
          patchMode: 'AutomaticByPlatform'
          automaticByPlatformSettings: { rebootSetting: 'IfRequired' }
        }
      }
      // Cloud-init runs once on first boot to install Docker + clone the repo
      customData: empty(cloudInitScript) ? null : cloudInitScript
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-noble'  // Ubuntu 24.04 LTS
        sku: '24_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        diskSizeGB: osDiskSizeGB
        managedDisk: { storageAccountType: 'StandardSSD_LRS' }
        deleteOption: 'Delete'   // disk deleted when VM is deleted
      }
    }
    networkProfile: {
      networkInterfaces: [{ id: nic.id, properties: { deleteOption: 'Delete' } }]
    }
    diagnosticsProfile: {
      bootDiagnostics: { enabled: true }   // helps debug boot failures in Azure portal
    }
  }
}

// Auto-shutdown at midnight UTC to save cost during dev/test
// Remove this resource once running in production 24/7
resource autoShutdown 'Microsoft.DevTestLab/schedules@2018-09-15' = {
  name: 'shutdown-computevm-${vm.name}'
  location: location
  properties: {
    status: 'Disabled'     // change to 'Enabled' if you want auto-shutdown
    taskType: 'ComputeVmShutdownTask'
    dailyRecurrence: { time: '0000' }
    timeZoneId: 'UTC'
    targetResourceId: vm.id
  }
}

// ── Outputs ───────────────────────────────────────────────────────────────────

output vmPublicIP string = publicIp.properties.ipAddress
output sshCommand string = 'ssh ${adminUsername}@${publicIp.properties.ipAddress}'
output vmPrincipalId string = vm.identity.principalId
output vmName string = vm.name
