# terraform-stages

A simple wrapper around terraform that supports sequential applications of terraform.
Basically, with terraform-stages one can specify multiple terraform projects to be applied sequentially.

## But why?

In certain scenarios it is currently not possible to specify the whole infrastructure in one terraform deployment.
This is mostly because providers cannot depend on one another.
See this terraform issue for more information: https://github.com/hashicorp/terraform/issues/2430

Let's look at a simple example:
Consider a simple deployment with a dockerized postgres DBMS that can be set up using the docker provider.
Now, one wants to configure a database within this server.
Normally, this is perfectly possible using the terraform postgres provider.
For configuring the postgres provider in terraform, the database needs to be up and running already in the planning phase.
This is however not yet the case, as the server needs to be spun up first.

For these cases terraform-stages can provide a solution:
Basically, you split up the configuration into two separate terraform deployments called stages.
In the first, you specify the setup for the postgres server, in the second stage you configure the server.
With terraform-stages it is possible to pass information from one stage to another using terraform outputs and variables.
Additionally, terraform-stages can be configured to wait for an URL to be available (e.g. the postgres url) before continuing with the next stage.
For a complete example see the `example` folder.

## Basic usage

In your base directory, create a folder for each stage you want to define.
In our example, we have two stages: `config` and `infrastructure`.
Within the folder create the terraform deployment as usual.

Create a `terraform-stages.yaml` file in the base directory.
A basic configuration might look like this:
```yaml
infrastructure: {}

config:
  depends_on:
  - stage: infrastructure
```

Here, the config stage needs to run *after* the infrastructure stage.
To apply this configuration, `cd` to your base directory (e.g. `example` in this repository) and call
```bash
terraform-stages.rb apply
```

To destroy it call
```bash
terraform-stages.rb destroy
```

## Variables

You can pass in variables by creating `.tfvars` files in the folder structure.
See the section on build directories for more details.

Additionally, you can specify that output variables of a stage should be used as input variables of another stage.
For example, to pass the `postgres_port` from the server setup to the configuration stage define it as output in the first stage:
```hcl
output "postgres_port" {
  value = docker_container.db.ports[0].external
}
```
Then, define it as input variable in the config stage:
```hcl
variable "postgres_port" {
  type = number
}
```
Finally, let terraform-stages know about your plan by specifying it in the `terraform-stages.yaml`:

```yaml
infrastructure: {}

config:
  depends_on:
  - stage: infrastructure
    variables:
    - postgres_port
```

Note, that the example in this repository already implements this.

## URL Dependencies

terraform-stages has the ability to delay application of a stage until a url is reachable.
In our example, we want to wait for the postgres server to be up and running before configuring it.
To configure this, add a url dependency in the `terraform-stages.yaml`:

```yaml
infrastructure: {}

config:
  depends_on:
  - stage: infrastructure
    variables:
    - postgres_port
  - url: http://localhost:9000
    timeout: 30
```

The optional timeout flag allows to set a timeout in seconds.
Default is 120 seconds.

Finally, it is also possible to use the variables defined in the stage dependencies (here only `postgres_port`) in the url:

```yaml
  - url: http://localhost:${postgres_port}
```

## Build directories / variants

terraform-stages has rudimentary support for build variants via a feature called build directories.
Basically build directories are folders with a similar structure as your base directory.
Any `.tfvars` files you put into this structure will be used when applying or destroying your deployment:
`.tfvars` files in the base directory will apply to all stages, `.tfvars` files in the subfolders will apply only the the stage with that name.
For an example have a look at the `example/variants/dev` and `example/variants/live` build directories.

To use a build directory, specify it when calling terraform-stages:
```bash
terraform-stages.rb apply/destroy -build-dir=path/to/build/dir
```
For example, to create the dev build of the example go to the `example` folder of this repository and call
```bash
terraform-stages.rb apply -build-dir=variants/dev
```

To make the variants feature complete, the terraform state will also be stored within the build directories.
Currently, terraform-stages does not support remote state.

The default build directory is always the base directory.
This means if no build directory is specified, any `.tfvars` files in the base directory or the stage directories will be included and the state will be stored within each stage directory.

## A note on the maturity of this project

This project is still in early alpha phase and many things might be subject to change in the future.
In the long term, we do hope that a terraform update might make this project obsolete - but as this issue https://github.com/hashicorp/terraform/issues/2430 is known since 2015 this might still take some time.

Until then, we already use terraform-stages successfully for our own deployments.
If you are interested, we would be glad to know your thoughts on the project.
