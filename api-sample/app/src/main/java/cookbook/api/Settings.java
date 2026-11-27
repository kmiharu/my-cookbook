package cookbook.api;

import java.net.URI;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;

/** Validates connection settings before any database client is built. */
public record Settings(
        String mode,
        boolean local,
        String table,
        URI dynamoEndpoint,
        URI streamsEndpoint,
        String jdbcUrl,
        String pgUser,
        String pgPassword,
        String pgSecretArn,
        int pgPoolSize
) {
    private static final Set<String> LOCAL_HOSTS = Set.of("localhost", "127.0.0.1", "[::1]", "dynamodb", "postgres");
    private static final Pattern LOCAL_JDBC = Pattern.compile(
            "jdbc:postgresql://(?:localhost|127\\.0\\.0\\.1|\\[::1\\]|postgres):([0-9]{1,5})/[a-zA-Z0-9_-]+");

    public static Settings fromEnvironment() {
        return from(System.getenv());
    }

    public static Settings from(Map<String, String> env) {
        String mode = required(env, "DATABASE_TYPE");
        if (!Set.of("dynamodb", "aurora", "hybrid").contains(mode)) {
            throw invalid("DATABASE_TYPE", "use dynamodb, aurora or hybrid");
        }
        String runtime = required(env, "APP_RUNTIME");
        if (!Set.of("local", "aws").contains(runtime)) {
            throw invalid("APP_RUNTIME", "use local or aws");
        }
        boolean local = runtime.equals("local");
        boolean dynamo = !mode.equals("aurora");
        boolean postgres = !mode.equals("dynamodb");

        String table = dynamo ? required(env, "DYNAMODB_TABLE") : null;
        URI endpoint = dynamo && local ? endpoint(env, "DYNAMODB_ENDPOINT") : null;
        URI stream = mode.equals("hybrid") && local && env.containsKey("DYNAMODB_STREAMS_ENDPOINT")
                ? endpoint(env, "DYNAMODB_STREAMS_ENDPOINT") : endpoint;

        String jdbcUrl = postgres ? required(env, "PG_JDBC_URL") : null;
        if (postgres && local) {
            var matcher = LOCAL_JDBC.matcher(jdbcUrl);
            if (!matcher.matches() || !validPort(Integer.parseInt(matcher.group(1)))) {
                throw invalid("PG_JDBC_URL", "use a PostgreSQL localhost/Compose URL with an explicit port");
            }
        }
        return new Settings(mode, local, table, endpoint, stream, jdbcUrl,
                postgres && local ? required(env, "PG_USER") : null,
                postgres && local ? required(env, "PG_PASSWORD") : null,
                postgres && !local ? required(env, "PG_SECRET_ARN") : null,
                postgres ? poolSize(env) : 0);
    }

    private static URI endpoint(Map<String, String> env, String name) {
        try {
            URI uri = URI.create(required(env, name));
            if ("http".equals(uri.getScheme()) && uri.getHost() != null && LOCAL_HOSTS.contains(uri.getHost())
                    && validPort(uri.getPort()) && uri.getUserInfo() == null && uri.getQuery() == null
                    && uri.getFragment() == null && Set.of("", "/").contains(uri.getPath())) {
                return uri;
            }
        } catch (IllegalArgumentException ignored) {
            // Keep credentials and invalid endpoint values out of configuration error messages.
        }
        throw invalid(name, "use an explicit HTTP localhost/Compose endpoint");
    }

    private static boolean validPort(int port) {
        return port >= 1 && port <= 65535;
    }

    private static int poolSize(Map<String, String> env) {
        try {
            int size = Integer.parseInt(env.getOrDefault("PG_POOL_SIZE", "4"));
            if (size >= 1 && size <= 32) {
                return size;
            }
        } catch (NumberFormatException ignored) {
            // Report the supported range below.
        }
        throw invalid("PG_POOL_SIZE", "use an integer between 1 and 32");
    }

    private static String required(Map<String, String> env, String name) {
        String value = env.get(name);
        if (value == null || value.isBlank()) {
            throw invalid(name, "a value is required");
        }
        return value;
    }

    private static IllegalArgumentException invalid(String name, String reason) {
        return new IllegalArgumentException(name + ": " + reason);
    }

    @Override
    public String toString() {
        return "Settings[mode=" + mode + ", local=" + local + "]";
    }
}
