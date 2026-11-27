plugins {
    id("org.springframework.boot") version "4.0.10" apply false
}

subprojects {
    apply(plugin = "java-library")
    group = "cookbook.batch"
    version = "1.0.0"

    repositories {
        mavenCentral()
    }

    extensions.configure<JavaPluginExtension> {
        toolchain.languageVersion.set(JavaLanguageVersion.of(21))
    }

    dependencies {
        add("implementation", platform("org.springframework.boot:spring-boot-dependencies:4.0.10"))
        add("implementation", platform("software.amazon.awssdk:bom:2.59.10"))
        add("testImplementation", platform("org.springframework.boot:spring-boot-dependencies:4.0.10"))
        add("testImplementation", "org.junit.jupiter:junit-jupiter")
        add("testRuntimeOnly", "org.junit.platform:junit-platform-launcher")
    }

    tasks.withType<JavaCompile>().configureEach {
        options.encoding = "UTF-8"
        options.compilerArgs.add("-parameters")
    }
    tasks.withType<Test>().configureEach {
        useJUnitPlatform()
        testLogging {
            events("passed", "skipped", "failed")
        }
    }
}
