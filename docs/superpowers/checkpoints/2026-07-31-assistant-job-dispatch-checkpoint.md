# Assistant Job Dispatch Checkpoint

**Date:** 2026-07-31
**Status:** Design discovery complete; implementation has not started.

## Requested capability

Add approval-free Assistant job dispatch so an explicit user request can send
selected targets through selected Whiterabbit templates or launch selected
Ansible playbooks. Also give the Assistant authoritative instructions for
writing valid Whiterabbit scripts based on the checked-in Whiterabbit source.

## Repository findings

- Whiterabbit dispatch currently creates one `ControlCenter::Job` for one saved
  template. `ControlCenter::SubmitJob` resolves the selected Hunter targets,
  writes a temporary target file, and calls `ControlCenter::Standalone`.
- Whiterabbit standalone accepts one `-run` template per invocation. A request
  containing multiple templates should therefore fan out into separately
  attributable and idempotent jobs rather than combine templates.
- Hunter targets and Sitemap endpoints are valid Whiterabbit input sources.
- Ansible uses a different trust model. `ControlCenter::Ansible::SingleLaunch`
  requires a saved playbook, a saved inventory with approved host keys, and a
  usable saved/default credential. HTTP target records cannot safely be turned
  into an Ansible inventory automatically.
- The current Assistant exposes Control Center job/run reads and artifact
  create/edit tools, but its mandatory prompt explicitly prohibits dispatch.
- The existing `get_authoring_policy` path can be expanded and exposed to the
  Claude chat backend instead of adding generic documentation or shell access.

## Recommended design direction

1. Add separate, narrowly named MCP execution tools for Whiterabbit dispatch
   and Ansible launch. Do not add a generic `send_job` tool.
2. Allow the tools only when the current user explicitly asks to send, run, or
   launch a job. No secondary confirmation dialog is required.
3. Whiterabbit accepts saved template IDs and explicit Hunter target/Sitemap
   IDs. Multiple templates fan out to one job per template with bounded total
   work, idempotency, attribution, and metadata-only audit events.
4. Ansible accepts saved playbook IDs and an existing approved inventory. It
   uses the inventory's approved/default credential path and never creates an
   inventory from Hunter HTTP targets.
5. Give each execution path a dedicated non-wildcard scope, closed request and
   response schemas, independent rate/work limits, and a revocation toggle.
6. Add a threat-model delta and update the explicit approved exception before
   implementation, because dispatch is a new effectful capability.
7. Expand the Whiterabbit authoring policy with code-derived rules for
   `__TARGET_STDIN__`, `__TARGET_FILE__`, `__UUID__`, target modes, output paths,
   argument grouping, and the exact `|`, `&&`, and `||` behavior. Instruct the
   model to retrieve this policy before authoring when needed.

## Pending decision

Confirm that Ansible launches must use an existing saved inventory with its
approved host keys and usable default/saved credential. This is the recommended
choice. Auto-generating an Ansible inventory from Hunter HTTP targets is out of
scope because it would bypass the existing SSH trust model.

## Resume sequence

1. Record the Ansible inventory decision.
2. Present two or three implementation approaches and the recommended complete
   capability design for approval.
3. Write and self-review the approved design specification.
4. Write the TDD implementation plan.
5. Implement test-first, run the complete Rails/Go/JavaScript verification, and
   request an independent Critical/Important code review.

No commit was created for this checkpoint.
