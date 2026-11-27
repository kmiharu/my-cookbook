package cookbook.api;

import io.micronaut.http.annotation.Produces;
import io.micronaut.http.HttpMethod;
import io.micronaut.http.HttpRequest;
import io.micronaut.http.HttpResponse;
import io.micronaut.http.HttpStatus;
import io.micronaut.http.MediaType;
import io.micronaut.http.MutableHttpResponse;
import io.micronaut.http.server.exceptions.ExceptionHandler;
import io.micronaut.http.server.exceptions.response.ErrorContext;
import io.micronaut.http.server.exceptions.response.ErrorResponseProcessor;
import io.micronaut.serde.annotation.Serdeable;
import jakarta.inject.Singleton;
import org.apache.ibatis.exceptions.PersistenceException;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import software.amazon.awssdk.core.exception.SdkException;

@Singleton
final class ApiErrors implements ErrorResponseProcessor<ApiErrors.Body> {
    private static final Logger LOG = LoggerFactory.getLogger(ApiErrors.class);

    @Override
    public MutableHttpResponse<Body> processResponse(ErrorContext context, MutableHttpResponse<?> response) {
        HttpRequest<?> request = context.getRequest();
        if (response.code() >= 500) {
            var failure = context.getRootCause().orElse(null);
            LOG.atError().addKeyValue("requestId", RequestLog.id(request))
                    .addKeyValue("errorType", failure == null ? "unknown" : failure.getClass().getName())
                    .log("HTTP request failed");
            if (failure instanceof SdkException || failure instanceof PersistenceException
                    || failure instanceof java.sql.SQLException) {
                response.status(HttpStatus.SERVICE_UNAVAILABLE);
            }
        }
        String code = response.code() == 400 ? "INVALID_REQUEST" : response.getStatus().name();
        return render(request, response, code, response.getStatus().getReason());
    }

    private static MutableHttpResponse<Body> render(HttpRequest<?> request, MutableHttpResponse<?> response,
                                                     String code, String message) {
        String requestId = RequestLog.id(request);
        response.getHeaders().set(RequestLog.HEADER, requestId);
        if (request.getMethod() == HttpMethod.HEAD) {
            return response.body(null);
        }
        return response.body(new Body(code, message, requestId)).contentType(MediaType.APPLICATION_JSON_TYPE);
    }

    @Serdeable
    record Body(String code, String message, String requestId) {}

    @Produces
    @Singleton
    static final class ProductProblems implements ExceptionHandler<ApiProblem, MutableHttpResponse<Body>> {
        @Override
        public MutableHttpResponse<Body> handle(HttpRequest request, ApiProblem failure) {
            return render(request, HttpResponse.status(failure.status()), failure.code(), failure.getMessage());
        }
    }
}
