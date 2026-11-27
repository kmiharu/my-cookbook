plugins { `java-library` }
dependencies {
    api(platform("software.amazon.awssdk:bom:2.59.10"))
    api("software.amazon.awssdk:s3")
    implementation("software.amazon.awssdk:sts")
    implementation("software.amazon.awssdk:url-connection-client")
    testImplementation("org.mockito:mockito-core")
}
