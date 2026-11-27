plugins { `java-library` }
dependencies {
    api(project(":batch-storage"))
    api("org.springframework.boot:spring-boot-starter-jdbc")
    implementation("org.postgresql:postgresql")
}
