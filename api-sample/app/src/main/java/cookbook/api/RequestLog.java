package cookbook.api;

import io.micronaut.http.HttpRequest;
import io.micronaut.http.MutableHttpResponse;
import io.micronaut.http.annotation.RequestFilter;
import io.micronaut.http.annotation.ResponseFilter;
import io.micronaut.http.annotation.ServerFilter;
import java.util.UUID;
import java.util.regex.Pattern;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

@ServerFilter("/**")
final class RequestLog {
    static final String HEADER = "X-Request-Id";
    private static final String ATTRIBUTE = "cookbook.requestId";
    private static final Pattern CLIENT_ID = Pattern.compile("[A-Za-z0-9._-]{1,64}");
    private static final Logger LOG = LoggerFactory.getLogger(RequestLog.class);

    @RequestFilter
    void request(HttpRequest<?> request) {
        id(request);
    }

    @ResponseFilter
    void response(HttpRequest<?> request, MutableHttpResponse<?> response) {
        String requestId = id(request);
        response.getHeaders().set(HEADER, requestId);
        if (!request.getPath().equals("/health")) {
            LOG.atInfo().addKeyValue("requestId", requestId)
                    .addKeyValue("method", request.getMethodName())
                    .addKeyValue("path", request.getPath())
                    .addKeyValue("status", response.code()).log("HTTP request completed");
        }
    }

    static String id(HttpRequest<?> request) {
        return request.getAttribute(ATTRIBUTE, String.class).orElseGet(() -> {
            String header = request.getHeaders().get(HEADER);
            String id = header != null && CLIENT_ID.matcher(header).matches() ? header : UUID.randomUUID().toString();
            request.setAttribute(ATTRIBUTE, id);
            return id;
        });
    }
}
