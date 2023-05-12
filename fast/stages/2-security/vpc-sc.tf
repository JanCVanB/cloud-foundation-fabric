/**
 * Copyright 2023 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

locals {
  _vpc_sc_vpc_accessible_services = null
  _vpc_sc_restricted_services = yamldecode(
    file("${path.module}/vpc-sc-restricted-services.yaml")
  )
  _vpc_sc_resources_lookup_folders = { for k, v in toset(flatten([
    [for k, v in var.vpc_sc_perimeters : v.folder_ids],
    [for k, v in var.vpc_sc_egress_policies : v.to.folder_ids],
    [for k, v in var.vpc_sc_ingress_policies : v.to.folder_ids],
    [for k, v in var.vpc_sc_ingress_policies : v.from.folder_ids],
  ])) : k => v }
  _vpc_sc_resources_lookup_projects = { for k, v in chunklist(sort(toset(flatten([
    [for k, v in var.vpc_sc_perimeters : v.project_ids],
    [for k, v in var.vpc_sc_egress_policies : v.to.project_ids],
    [for k, v in var.vpc_sc_ingress_policies : v.to.project_ids],
    [for k, v in var.vpc_sc_ingress_policies : v.from.project_ids],
  ]))), 50) : k => v }
  _vpc_sc_resources_projects_in_folders = {
    for k in local._vpc_sc_resources_lookup_folders :
    k => formatlist("projects/%s", data.google_projects.project_in_folders[k].projects[*].number)
  }
  _vpc_sc_resources_projects_by_ids = {
    for k in flatten(values(data.google_projects.project_by_ids)[*].projects) :
    k.project_id => "projects/${k.number}"
  }
  # compute the number of projects in each perimeter to detect which to create
  vpc_sc_counts = {
    for k, v in var.vpc_sc_perimeters : k => length(v.resources)
  }
  # define dry run spec at file level for convenience
  vpc_sc_explicit_dry_run_spec = true
  # compute perimeter bridge resources (projects)
  vpc_sc_perimeter_resources = {
    for k, v in var.vpc_sc_perimeters : k => sort(toset(flatten([
      v.resources,
      [for f in v.folder_ids : local._vpc_sc_resources_projects_in_folders[f]],
      [for f in v.project_ids : local._vpc_sc_resources_projects_by_ids[f]]
    ])))
  }
  vpc_sc_perimeters_spec_status = {
    for k, v in var.vpc_sc_perimeters : k => merge([
      v,
      {
        resources               = local.vpc_sc_perimeter_resources[k]
        restricted_services     = local._vpc_sc_restricted_services
        vpc_accessible_services = local._vpc_sc_vpc_accessible_services
        project_ids             = null
        folder_ids              = null
      },
    ]...)
  }
  vpc_sc_bridge_resources = {
    for p in setproduct(["landing"], ["dev", "prod"]) :
    "${p.0}_to_${p.1}" => sort(toset(flatten([
      local.vpc_sc_perimeter_resources[p.0],
      local.vpc_sc_perimeter_resources[p.1],
    ])))
  }
  vpc_sc_egress_policies = {
    for k, v in var.vpc_sc_egress_policies :
    k => {
      from = v.from
      to = merge([
        v.to,
        {
          resources = sort(toset(flatten([
            v.to.resources,
            [for f in v.to.folder_ids : local._vpc_sc_resources_projects_in_folders[f]],
            [for f in v.to.project_ids : local._vpc_sc_resources_projects_by_ids[f]],
          ])))
          project_ids = null
          folder_ids  = null
        }
      ]...)
    }
  }

  vpc_sc_ingress_policies = {
    for k, v in var.vpc_sc_ingress_policies :
    k => {
      from = merge([
        v.from,
        {
          resources = sort(toset(flatten([
            v.from.resources,
            [for f in v.from.folder_ids : local._vpc_sc_resources_projects_in_folders[f]],
            [for f in v.from.project_ids : local._vpc_sc_resources_projects_by_ids[f]],
          ])))
          project_ids = null
          folder_ids  = null
        }
      ]...)
      to = merge([
        v.to,
        {
          resources = sort(toset(flatten([
            v.to.resources,
            [for f in v.to.folder_ids : local._vpc_sc_resources_projects_in_folders[f]],
            [for f in v.to.project_ids : local._vpc_sc_resources_projects_by_ids[f]],
          ])))
          project_ids = null
          folder_ids  = null
        }
      ]...)
    }
  }
}

data "google_projects" "project_by_ids" {
  for_each = local._vpc_sc_resources_lookup_projects
  filter   = "(${join(" OR ", formatlist("id=%s", each.value))}) AND lifecycleState:ACTIVE"
}

data "google_projects" "project_in_folders" {
  for_each = local._vpc_sc_resources_lookup_folders
  filter   = "parent.type=folder parent.id=${each.value} AND lifecycleState:ACTIVE"
}

module "vpc-sc" {
  source = "../../../modules/vpc-sc"
  # only enable if we have projects defined for perimeters
  count         = anytrue([for k, v in local.vpc_sc_counts : v > 0]) ? 1 : 0
  access_policy = null
  access_policy_create = {
    parent = "organizations/${var.organization.id}"
    title  = "default"
  }
  access_levels    = var.vpc_sc_access_levels
  egress_policies  = local.vpc_sc_egress_policies
  ingress_policies = local.vpc_sc_ingress_policies
  service_perimeters_bridge = merge(
    # landing to dev, only we have projects in landing and dev perimeters
    local.vpc_sc_counts.landing * local.vpc_sc_counts.dev == 0 ? {} : {
      landing_to_dev = {
        spec_resources = (
          local.vpc_sc_explicit_dry_run_spec
          ? local.vpc_sc_bridge_resources.landing_to_dev
          : null
        )
        status_resources = (
          local.vpc_sc_explicit_dry_run_spec
          ? null
          : local.vpc_sc_bridge_resources.landing_to_dev
        )
        use_explicit_dry_run_spec = local.vpc_sc_explicit_dry_run_spec
      }
    },
    # landing to prod, only we have projects in landing and prod perimeters
    local.vpc_sc_counts.landing * local.vpc_sc_counts.prod == 0 ? {} : {
      landing_to_prod = {
        spec_resources = (
          local.vpc_sc_explicit_dry_run_spec
          ? local.vpc_sc_bridge_resources.landing_to_prod
          : null
        )
        status_resources = (
          local.vpc_sc_explicit_dry_run_spec
          ? null
          : local.vpc_sc_bridge_resources.landing_to_prod
        )
        use_explicit_dry_run_spec = local.vpc_sc_explicit_dry_run_spec
      }
    }
  )
  # regular type perimeters
  service_perimeters_regular = merge(
    # dev if we have projects in var.vpc_sc_perimeter_projects.dev
    local.vpc_sc_counts.dev == 0 ? {} : {
      dev = {
        spec = (
          local.vpc_sc_explicit_dry_run_spec
          ? local.vpc_sc_perimeters_spec_status.dev
          : null
        )
        status = (
          local.vpc_sc_explicit_dry_run_spec
          ? null
          : local.vpc_sc_perimeters_spec_status.dev
        )
        use_explicit_dry_run_spec = local.vpc_sc_explicit_dry_run_spec
      }
    },
    # landing if we have projects in var.vpc_sc_perimeter_projects.landing
    local.vpc_sc_counts.landing == 0 ? {} : {
      landing = {
        spec = (
          local.vpc_sc_explicit_dry_run_spec
          ? local.vpc_sc_perimeters_spec_status.landing
          : null
        )
        status = (
          local.vpc_sc_explicit_dry_run_spec
          ? null
          : local.vpc_sc_perimeters_spec_status.landing
        )
        use_explicit_dry_run_spec = local.vpc_sc_explicit_dry_run_spec
      }
    },
    # prod if we have projects in var.vpc_sc_perimeter_projects.prod
    local.vpc_sc_counts.prod == 0 ? {} : {
      prod = {
        spec = (
          local.vpc_sc_explicit_dry_run_spec
          ? local.vpc_sc_perimeters_spec_status.prod
          : null
        )
        status = (
          local.vpc_sc_explicit_dry_run_spec
          ? null
          : local.vpc_sc_perimeters_spec_status.prod
        )
        use_explicit_dry_run_spec = local.vpc_sc_explicit_dry_run_spec
      }
    },
  )
}
