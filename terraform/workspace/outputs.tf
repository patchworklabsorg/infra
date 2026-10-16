output "group_emails" {
  description = "Group address by group key."
  value       = { for k, g in googleworkspace_group.this : k => g.email }
}

output "org_unit_paths" {
  description = "Org unit path by key."
  value = merge(
    { for k, o in googleworkspace_org_unit.top : k => o.org_unit_path },
    { for k, o in googleworkspace_org_unit.sponsored : k => o.org_unit_path },
  )
}
