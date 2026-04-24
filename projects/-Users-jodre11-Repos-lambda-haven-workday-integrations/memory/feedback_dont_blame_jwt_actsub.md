---
name: Don't blame JWT act.sub for Workday API failures
description: User corrected repeated assumption that empty act.sub was causing WQL 403 — three other REST endpoints worked fine with the same empty claim
type: feedback
originSessionId: 6788a956-c34a-4742-8036-079485c5a47d
---
Do not assume the JWT `act.sub` claim is the cause of Workday API failures. When investigating the
WQL 403, I repeatedly suggested regenerating the refresh token to fix the empty `act.sub`. The user
explicitly corrected this: "Refresh token generation is not the problem. I know you don't believe
me. There is something else we need to enable."

**Why:** Workers REST, Staffing REST, and WQL dataSources all returned 200 with the same token
carrying an empty `act.sub`. If those endpoints work, the JWT identity is sufficient. The 403 on
WQL query execution had a different cause (GET vs POST, plus missing domain permissions).

**How to apply:** When debugging Workday API failures, check what DOES work with the same token
before blaming the token itself. If multiple endpoints succeed with the same token, the token is
not the problem. Accept user corrections about their own systems sooner rather than re-suggesting
the same theory.
