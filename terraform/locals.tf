locals {
  input_yaml = yamldecode(file("deployment.yaml"))
  handler_ref = try(local.input_yaml["lambda_automation"])
  handler_selection = local.handler_ref != "FULL_AUTO" ? "handler-automatic-close-and-merge.py" : (local.handler_ref == "AUTO_CLOSE" ? "handler-automatic-close.py" : (local.handler_ref == "APPROVE_ONLY" ? "handler.py" : null ))

  # accepted modes are FULL_AUTO, AUTO_CLOSE, APPROVE_ONLY

  # Name Construction
  # -----------------

  customer_prefix = try(local.input_yaml["customer_prefix"])
  project_uid     = try(local.input_yaml["project_uid"])
  resource_prefix = "${local.customer_prefix}-${local.project_uid}"

  # List Building
  # -------------
  codecommit = try(local.input_yaml["codecommit"], {})
  iam        = try(local.input_yaml["iam"], {})

  # >>>> Repositories
  repositories_deploy = try(flatten([
    for val in local.codecommit["repositories"] : [
      for approvals in val["approval_templates"] : {
        id                 = val["id"]
        name               = val["id"]
        reference_existing = val["reference_existing"]
        approval_templates = val["approval_templates"]
      } if tostring(val["reference_existing"]) == "false"
    ]
    ]
  ), {})

  repositories_existing = try(flatten([
    for val in local.codecommit["repositories"] : [
      for approvals in val["approval_templates"] : {
        id                 = val["id"]
        name               = val["id"]
        reference_existing = val["reference_existing"]
      } if tostring(val["reference_existing"]) == "true"
    ]
    ]
  ), {})

  # >>>> Approval Templates
  approval_templates_deploy = try(flatten([
    for val in local.codecommit["approval_templates"] : [
      for mem in val["pool_members"] : {
        id                 = val["id"]
        name               = val["id"]
        reference_existing = val["reference_existing"]
        approvals_needed   = val["approvals_needed"]
        pool_members       = val["pool_members"]
        automated_reviews  = val["automated_reviews"]
      } if tostring(val["reference_existing"]) == "false"
    ]
    ]
  ), {})

  approval_templates_existing = try(flatten([
    for val in local.codecommit["approval_templates"] : {
      id                 = val["id"]
      name               = val["id"]
      reference_existing = val["reference_existing"]
    } if tostring(val["reference_existing"]) == "true"
    ]
  ), {})

  # >>>> IAM Assumed Roles 
  assumed_roles_deploy = try(flatten([
    for val in local.iam["assumed_roles"] : {
      id                 = val["id"]
      name               = val["id"]
      reference_existing = val["reference_existing"]
    } if tostring(val["reference_existing"]) == "false"
    ]
  ), {})

  assumed_roles_existing = try(flatten([
    for val in local.iam["assumed_roles"] : {
      id                 = val["id"]
      name               = val["id"]
      reference_existing = val["reference_existing"]
    } if tostring(val["reference_existing"]) == "true"
    ]
  ), {})

  # <<<<<<< END OF LOCALS
}