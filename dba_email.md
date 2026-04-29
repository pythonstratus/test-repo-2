Subject: Request: Dry Run of ENTITY Deployment Scripts Before Prod

Hi Christina,

As we prepare for the ENTITY schema deployment to Prod, we'd like to propose a dry run of the scripts beforehand to make sure everything executes cleanly in the production environment.

Here's what we have in mind:

- We'll provide you the complete set of deployment scripts (master_run.sql and all referenced object scripts).
- The scripts would need to be executed as two different synthetic (test) users to validate that permissions, grants, and object creation all work as expected under the access patterns we'll have in Prod.
- This gives us a chance to catch any issues — missing grants, dependency ordering problems, or environment-specific differences — before we run against the actual Prod schema.

Would your team be able to support this approach? Happy to walk through the scripts and the two test user scenarios in more detail whenever works for you.

Thanks,
Santosh
