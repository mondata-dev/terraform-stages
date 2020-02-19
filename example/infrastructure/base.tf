################
### Provider ###
################
provider "docker" {
  # as no host is provided, localhost is implicitly assumed
}

##############
### Images ###
##############

resource "docker_image" "postgres" {
  name = "postgres"
  keep_locally = true
}

#################
### Container ###
#################
resource "docker_container" "db" {
  image = docker_image.postgres.latest
  name  = "postgres"

  env = [
    "POSTGRES_PASSWORD=secret"
  ]
  
  # Enable this if you need development access to db
  ports {
    internal = 5432
    external = 9000
  }
}
