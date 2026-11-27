package cookbook.api;

import io.micronaut.http.HttpStatus;

final class ApiProblem extends RuntimeException {
    private final HttpStatus status;
    private final String code;

    ApiProblem(HttpStatus status, String code, String message) {
        super(message);
        this.status = status;
        this.code = code;
    }

    HttpStatus status() {
        return status;
    }

    String code() {
        return code;
    }

    static ApiProblem invalid(String message) {
        return new ApiProblem(HttpStatus.BAD_REQUEST, "INVALID_REQUEST", message);
    }

    static ApiProblem notFound() {
        return new ApiProblem(HttpStatus.NOT_FOUND, "PRODUCT_NOT_FOUND", "Product does not exist");
    }

    static ApiProblem conflict() {
        return new ApiProblem(HttpStatus.PRECONDITION_FAILED, "VERSION_CONFLICT", "Product version has changed");
    }
}
