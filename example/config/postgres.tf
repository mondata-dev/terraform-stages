provider "postgresql" {
  host            = "localhost"
  port            = 9000
#   database        = "postgres"
  username        = "postgres"
  password        = "secret"
  sslmode         = "disable"
#   connect_timeout = 15
}

resource "postgresql_database" "example_db" {
  name = "example_db"
}
