plugins { `java-library` }
dependencies {
    api(platform("software.amazon.awssdk:bom:2.59.10"))
    api("software.amazon.awssdk:dynamodb")
    implementation("software.amazon.awssdk:url-connection-client")
    testImplementation("org.mockito:mockito-core")
}
