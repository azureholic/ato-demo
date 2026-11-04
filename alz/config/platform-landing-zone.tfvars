# Adapted from Azure/alz-terraform-accelerator v17.6.0, smb-single-region.
starter_locations = ["belgiumcentral"]

custom_replacements = {
  names = {
    defender_email_security_contact = "__SECURITY_CONTACT_EMAIL__"

    ddos_protection_plan_enabled                          = false
    primary_firewall_enabled                              = true
    primary_firewall_sku_tier                             = "Basic"
    primary_virtual_network_gateway_express_route_enabled = false
    primary_virtual_network_gateway_vpn_enabled           = false
    primary_private_dns_zones_enabled                     = false
    primary_private_dns_auto_registration_zone_enabled    = false
    primary_private_dns_resolver_enabled                  = false
    primary_bastion_enabled                               = false

    management_resource_group_name               = "rg-management-$${starter_location_01}"
    connectivity_hub_primary_resource_group_name = "rg-hub-$${starter_location_01}"
    dns_resource_group_name                      = "rg-hub-dns-$${starter_location_01}"
    ddos_resource_group_name                     = "rg-hub-ddos-$${starter_location_01}"
    asc_export_resource_group_name               = "rg-asc-export-$${starter_location_01}"
    service_health_alerts_resource_group_name    = "rg-service-health-alerts-$${starter_location_01}"

    log_analytics_workspace_name            = "law-management-$${starter_location_01}"
    ddos_protection_plan_name               = "ddos-$${starter_location_01}"
    ama_user_assigned_managed_identity_name = "uami-management-ama-$${starter_location_01}"
    dcr_change_tracking_name                = "dcr-change-tracking"
    dcr_defender_sql_name                   = "dcr-defender-sql"
    dcr_vm_insights_name                    = "dcr-vm-insights"
    primary_hub_address_space               = "10.100.0.0/16"
  }
  resource_group_identifiers = {
    management_resource_group_id           = "/subscriptions/$${subscription_id_management}/resourceGroups/$${management_resource_group_name}"
    ddos_protection_plan_resource_group_id = "/subscriptions/$${subscription_id_connectivity}/resourceGroups/$${ddos_resource_group_name}"
    primary_connectivity_resource_group_id = "/subscriptions/$${subscription_id_connectivity}/resourceGroups/$${connectivity_hub_primary_resource_group_name}"
    dns_resource_group_id                  = "/subscriptions/$${subscription_id_connectivity}/resourceGroups/$${dns_resource_group_name}"
  }
  resource_identifiers = {
    ama_change_tracking_data_collection_rule_id = "$${management_resource_group_id}/providers/Microsoft.Insights/dataCollectionRules/$${dcr_change_tracking_name}"
    ama_mdfc_sql_data_collection_rule_id        = "$${management_resource_group_id}/providers/Microsoft.Insights/dataCollectionRules/$${dcr_defender_sql_name}"
    ama_vm_insights_data_collection_rule_id     = "$${management_resource_group_id}/providers/Microsoft.Insights/dataCollectionRules/$${dcr_vm_insights_name}"
    ama_user_assigned_managed_identity_id       = "$${management_resource_group_id}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$${ama_user_assigned_managed_identity_name}"
    log_analytics_workspace_id                  = "$${management_resource_group_id}/providers/Microsoft.OperationalInsights/workspaces/$${log_analytics_workspace_name}"
    ddos_protection_plan_id                     = "$${ddos_protection_plan_resource_group_id}/providers/Microsoft.Network/ddosProtectionPlans/$${ddos_protection_plan_name}"
  }
}

tags = {
  deployed_by = "terraform"
  source      = "Azure Landing Zones Accelerator"
  environment = "smb"
}

management_resources_enabled = true
management_resource_settings = {
  location                     = "$${starter_location_01}"
  log_analytics_workspace_name = "$${log_analytics_workspace_name}"
  resource_group_name          = "$${management_resource_group_name}"
  user_assigned_managed_identities = {
    ama = { name = "$${ama_user_assigned_managed_identity_name}" }
  }
  data_collection_rules = {
    change_tracking = { name = "$${dcr_change_tracking_name}" }
    defender_sql    = { name = "$${dcr_defender_sql_name}" }
    vm_insights     = { name = "$${dcr_vm_insights_name}" }
  }
}

management_groups_enabled = true
management_group_settings = {
  architecture_name  = "alz_custom"
  location           = "$${starter_location_01}"
  parent_resource_id = "$${root_parent_management_group_id}"
  policy_default_values = {
    ama_change_tracking_data_collection_rule_id = "$${ama_change_tracking_data_collection_rule_id}"
    ama_mdfc_sql_data_collection_rule_id        = "$${ama_mdfc_sql_data_collection_rule_id}"
    ama_vm_insights_data_collection_rule_id     = "$${ama_vm_insights_data_collection_rule_id}"
    ama_user_assigned_managed_identity_id       = "$${ama_user_assigned_managed_identity_id}"
    ama_user_assigned_managed_identity_name     = "$${ama_user_assigned_managed_identity_name}"
    log_analytics_workspace_id                  = "$${log_analytics_workspace_id}"
    resource_group_name_service_health_alerts   = "$${service_health_alerts_resource_group_name}"
    resource_group_name_mdfc                    = "$${asc_export_resource_group_name}"
    resource_group_location                     = "$${starter_location_01}"
    email_security_contact                      = "$${defender_email_security_contact}"
  }
  # A subscription can have only one parent management group.
  subscription_placement = {
    shared_platform = {
      subscription_id       = "$${subscription_id_management}"
      management_group_name = "platform"
    }
  }
  policy_assignments_to_modify = {
    alz = {
      policy_assignments = {
        Deploy-MDFC-Config-H224 = {
          parameters = {
            enableAscForServers                         = "DeployIfNotExists"
            enableAscForServersVulnerabilityAssessments = "DeployIfNotExists"
            enableAscForSql                             = "DeployIfNotExists"
            enableAscForAppServices                     = "DeployIfNotExists"
            enableAscForStorage                         = "DeployIfNotExists"
            enableAscForContainers                      = "DeployIfNotExists"
            enableAscForKeyVault                        = "DeployIfNotExists"
            enableAscForSqlOnVm                         = "DeployIfNotExists"
            enableAscForArm                             = "DeployIfNotExists"
            enableAscForOssDb                           = "DeployIfNotExists"
            enableAscForCosmosDbs                       = "DeployIfNotExists"
            enableAscForCspm                            = "DeployIfNotExists"
          }
        }
      }
    }
    connectivity = {
      policy_assignments = {
        Enable-DDoS-VNET = { creation_enabled = false }
      }
    }
    landingzones = {
      policy_assignments = {
        Enable-DDoS-VNET = { creation_enabled = false }
      }
    }
    corp = {
      policy_assignments = {
        Deploy-Private-DNS-Zones = { creation_enabled = false }
      }
    }
  }
}

connectivity_type = "hub_and_spoke_vnet"
connectivity_resource_groups = {
  ddos = {
    name     = "$${ddos_resource_group_name}"
    location = "$${starter_location_01}"
    settings = { enabled = "$${ddos_protection_plan_enabled}" }
  }
  vnet_primary = {
    name     = "$${connectivity_hub_primary_resource_group_name}"
    location = "$${starter_location_01}"
    settings = { enabled = true }
  }
  dns = {
    name     = "$${dns_resource_group_name}"
    location = "$${starter_location_01}"
    settings = { enabled = "$${primary_private_dns_zones_enabled}" }
  }
}
hub_and_spoke_networks_settings = {
  enabled_resources = {
    ddos_protection_plan = "$${ddos_protection_plan_enabled}"
  }
  ddos_protection_plan = {
    name                = "$${ddos_protection_plan_name}"
    resource_group_name = "$${ddos_resource_group_name}"
    location            = "$${starter_location_01}"
  }
}
hub_virtual_networks = {
  primary = {
    location                  = "$${starter_location_01}"
    default_parent_id         = "$${primary_connectivity_resource_group_id}"
    default_hub_address_space = "$${primary_hub_address_space}"
    enabled_resources = {
      firewall                              = "$${primary_firewall_enabled}"
      bastion                               = "$${primary_bastion_enabled}"
      virtual_network_gateway_express_route = "$${primary_virtual_network_gateway_express_route_enabled}"
      virtual_network_gateway_vpn           = "$${primary_virtual_network_gateway_vpn_enabled}"
      private_dns_zones                     = "$${primary_private_dns_zones_enabled}"
      private_dns_resolver                  = "$${primary_private_dns_resolver_enabled}"
    }
    firewall        = { sku_tier = "$${primary_firewall_sku_tier}" }
    firewall_policy = { sku = "$${primary_firewall_sku_tier}" }
    private_dns_zones = {
      parent_id = "$${dns_resource_group_id}"
    }
  }
}

enable_telemetry = true
