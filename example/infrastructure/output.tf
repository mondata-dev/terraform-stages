output "postgres_port" {
  value = docker_container.db.ports[0].external
}
