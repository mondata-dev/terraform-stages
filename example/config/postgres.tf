provider "postgresql" {
  host            = "localhost"
  port            = var.postgres_port
  username        = "postgres"
  password        = var.postgres_password
  sslmode         = "disable"
}

resource "postgresql_database" "example_db" {
  name = var.db_name
}
