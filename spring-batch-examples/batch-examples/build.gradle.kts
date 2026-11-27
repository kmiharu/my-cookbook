plugins {
    `java-library`
    id("org.springframework.boot")
}
dependencies {
    implementation(project(":batch-common"))
    implementation(project(":batch-file"))
    implementation(project(":batch-storage"))
    implementation(project(":batch-database"))
    implementation(project(":batch-dynamodb"))
    implementation("org.springframework.boot:spring-boot-starter-batch-jdbc")
    implementation("org.springframework.boot:spring-boot-starter-flyway")
    implementation("org.flywaydb:flyway-database-postgresql")
    implementation("org.mybatis.spring.boot:mybatis-spring-boot-starter:4.0.1")
    implementation("org.postgresql:postgresql")
    implementation("com.fasterxml.jackson.core:jackson-databind")
    testImplementation("org.springframework.boot:spring-boot-starter-test")
    testImplementation("org.testcontainers:testcontainers-postgresql")
    testImplementation("org.testcontainers:testcontainers-junit-jupiter")
}
springBoot { mainClass.set("cookbook.batch.examples.BatchApplication") }
tasks.bootJar { archiveFileName.set("batch-examples.jar") }
