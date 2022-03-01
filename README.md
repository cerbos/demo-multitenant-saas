# Multitenant SaaS platform demo

This demo shows how to use Cerbos's [scoped policies](https://docs.cerbos.dev/cerbos/latest/policies/scoped_policies.html) (available in 0.13+) to model a multitenant SaaS platform, where each tenant may have specific authorization requirements.

## Scenario

### Resources

We're going to look at authorizing access to a single kind of resource: purchase orders.

### Principals

On this SaaS platform, users can hold multiple roles, depending on how they are assigned to resources:

- **customer** users are assigned to their tenant;
- **operations** users (staff of the SaaS provider) are assigned to the tenants that they manage; and
- **manufacturer** users belong to organizations, which are assigned to manufacture specific purchase orders.

It's possible for a user to be a customer in one tenant but also to belong to an organization that manufactures purchase orders for another tenant.

### Actions

There are three actions we need to authorize on a purchase order resource:

- `prepareForDelivery` may be performed by manufacturers assigned to the purchase order;
- `sendInvoice` may be performed by operations assigned to the purchase order's tenant; and
- `view` may be performed by manufacturers assigned to the purchase order, and customers or operations assigned to the purchase order's tenant.

#### Tenant-specific requirements

One tenant, Vanilla Ltd., doesn't have any authorization requirements beyond the base set of permissions described above.

The other, Regional Corp., is divided internally into APAC and EMEA regions.
In this tenant, purchase orders are allocated to a region, and customer users are allocated to one or both regions.
Customers should not be able to view purchase orders if they are not allocated to the purchase order's region.

## Solution

We'll use [scoped policies](https://docs.cerbos.dev/cerbos/latest/policies/scoped_policies.html), and implement the base set of permissions in the root scope.
Tenant-specific requirements can then be layered in policies scoped to the tenant's identifier.
That way, applications requesting authorization decisions from Cerbos don't have to be aware of the tenant's authorization requirements - they just send the tenant identifier as the `scope` on the resources.

We'll use [derived roles](https://docs.cerbos.dev/cerbos/latest/policies/derived_roles.html) to convert the user's assignments into the role they have for the purchase order being authorized.

### Principals

We'll send purchase order resources to Cerbos in this format:

#### Vanilla Ltd. customers

```yaml
{
  "id": "alice@vanilla.example.com",
  "roles": ["user"],
  "attr": {
    "tenantAssignments": {
      "customer": ["vanilla"]
    }
  }
}
```

#### Regional Corp. customers

```yaml
{
  "id": "bob@regional.example.com",
  "roles": ["user"],
  "attr": {
    "tenantAssignments": {
      "customer": ["regional"]
    },
    "regions": ["apac"] # and/or "emea"
  }
}
```

#### SaaS provider operations

```yaml
{
  "id": "carol@saas-provider.example.com",
  "roles": ["user"],
  "attr": {
    "tenantAssignments": {
      "operations": ["vanilla"] # and/or "regional"
    }
  }
}
```

#### Acme Inc. manufacturers

```yaml
{
  "id": "dave@acme.example.com",
  "roles": ["user"],
  "attr": {
    "organizations": ["acme"]
  }
}
```

### Resources

We'll send purchase order resources to Cerbos in this format:

```yaml
{
  "id": "ABC-123",
  "kind": "purchase_order",
  "scope": "regional", # or "vanilla"
  "attr": {
    "tenant": "regional", # or "vanilla"
    "organizationAssignments": {
      "manufacturer": ["acme"]
    },
    "region": "apac" # or "emea"; omitted for the "vanilla" tenant
  }
}
```

### Derived roles

We can derive the `customer` and `operations` roles by checking if the purchase order resource's `tenant` is in the principal's corresponding `tenantAssignments`:

```yaml
apiVersion: api.cerbos.dev/v1
derivedRoles:
  name: tenant_assignments
  definitions:
    - name: customer
      parentRoles:
        - user
      condition:
        match:
          expr: R.attr.tenant in P.attr.tenantAssignments.customer

    - name: operations
      parentRoles:
        - user
      condition:
        match:
          expr: R.attr.tenant in P.attr.tenantAssignments.operations
```

We can derive the `manufacturer` role by checking for overlap between the purchase order resource's `organizationAssignments` and the principal's `organizations`:

```yaml
apiVersion: api.cerbos.dev/v1
derivedRoles:
  name: organization_assignments
  definitions:
    - name: manufacturer
      parentRoles:
        - user
      condition:
        match:
          expr: hasIntersection(R.attr.organizationAssignments.manufacturer, P.attr.organizations)
```

### Resource policies

With the derived roles in place, we can define the base set of permissions in a resource policy in the root scope:

```yaml
apiVersion: api.cerbos.dev/v1
resourcePolicy:
  version: default
  resource: purchase_order
  importDerivedRoles:
    - organization_assignments
    - tenant_assignments
  rules:
    - actions:
        - prepareForDelivery
      effect: EFFECT_ALLOW
      derivedRoles:
        - manufacturer

    - actions:
        - sendInvoice
      effect: EFFECT_ALLOW
      derivedRoles:
        - operations

    - actions:
        - view
      effect: EFFECT_ALLOW
      derivedRoles:
        - customer
        - manufacturer
        - operations
```

For Vanilla Inc., we don't want to introduce any additional rules, so we can define an empty scoped policy (note that this requires Cerbos 0.14+; in 0.13, policies must define at least one rule):

```yaml
apiVersion: api.cerbos.dev/v1
resourcePolicy:
  version: default
  resource: purchase_order
  scope: vanilla
```

For Regional Corp., we'll define a scoped policy that denies `view` access to customers who aren't allocated to the purchase order resource's region:

```yaml
apiVersion: api.cerbos.dev/v1
resourcePolicy:
  version: default
  resource: purchase_order
  scope: regional
  importDerivedRoles:
    - tenant_assignments
  rules:
    - actions:
        - view
      effect: EFFECT_DENY
      derivedRoles:
        - customer
      condition:
        match:
          expr: |-
            !(R.attr.region in P.attr.regions)
```

The remaining rules will be enforced by falling back to the root policy.
Note that we opted to deny non-matching regions in the scoped policy rather than allowing matching regions; this means we could introduce further conditions to the allow rule in the root policy without having to duplicate them in the scoped policy.

### Success!

With these policies in place, we can now authorize the required actions, and the tenant-specific authorization requirements are encapsulated in Cerbos without leaking into our applications.

## Try it out

You can clone this repository and run `make` to run a set of [tests](https://docs.cerbos.dev/cerbos/latest/policies/compile.html#_testing_policies) that exercise the policies.
This requires Docker to be [installed](https://docs.docker.com/get-docker/) and [authenticated to the GitHub container registry (ghcr.io)](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry#authenticating-to-the-container-registry).
Alternatively, if you have Cerbos 0.14+ [installed locally](https://docs.cerbos.dev/cerbos/latest/installation/binary.html), you can run

```console
$ cerbos compile --tests=tests policies
```

## Learn more

- [Documentation](https://docs.cerbos.dev)
- [Guide](https://book.cerbos.dev)
- [Website](https://cerbos.dev)
