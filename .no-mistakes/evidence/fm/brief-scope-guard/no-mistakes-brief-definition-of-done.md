Generated crewmate brief (bin/fm-brief.sh <id> demo-proj --mode no-mistakes), target commit 48a9167.
This is the file a crewmate agent actually reads: $FM_HOME/data/<id>/brief.md

# Definition of done
Delivery contract: mode=no-mistakes
The task is complete only when committed on your branch.
When you believe it is complete, append `done: {summary}` to the status file and stop.
Firstmate will then instruct you to run /no-mistakes to validate and ship a PR.

You drive no-mistakes by responding to its gates, not by implementing fixes.
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke /no-mistakes, and `no-mistakes axi run --help` plus the `help` lines in each `axi` response are authoritative and version-matched to the installed binary.
When starting no-mistakes, make `--intent` preserve all relevant content from this brief's `# Task` section plus every later accepted Firstmate requirement, clarification, constraint, exclusion, and supersession, carrying only each requirement's current accepted form; retain direct requirements instead of substituting a diff summary, and exclude generic operational, status, delivery, and other scaffold boilerplate unless it is task-specific.
Do not hand-edit, commit, or fix findings yourself while a run is active - the pipeline applies every fix.

Three firstmate-specific rules layer on top of that guidance:
- ask-user findings are never yours to answer: escalate to firstmate (rule 6) and stop.
  Firstmate applies `ask-user-authority` and obtains any required captain decision.
  When the decision comes back, feed it to the gate with `no-mistakes axi respond` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.
- Widening beyond scope is never yours to accept: the pipeline may fix what the run's own findings identify, including the smallest downstream changes needed to keep already-accepted behavior correct per `ask-user-authority` (for example, a security-advisory dependency bump the findings themselves call for).
  A fix that goes past the task's stated scope - an unrelated improvement the pipeline noticed along the way rather than a correction the accepted work requires - stops there: append `needs-decision: {summary}` (rule 6) and let firstmate decide before it applies.
  You drive the gate and see every proposed fix before it lands, so noticing this is on you.
- Avoid `--yes`: it would silently bypass firstmate's authority check and any required captain escalation.

After /no-mistakes reports CI green (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), append `done: PR {url} checks green` and stop. You are finished.
