pluginManagement {
    repositories { mavenCentral(); gradlePluginPortal() }
    resolutionStrategy { eachPlugin { if (requested.id.id == "org.springframework.boot") useModule("org.springframework.boot:spring-boot-gradle-plugin:${requested.version}") } }
}

rootProject.name = "spring-batch-cookbook"
include("batch-common", "batch-file", "batch-storage", "batch-database", "batch-dynamodb", "batch-examples", "batch-test-support")
