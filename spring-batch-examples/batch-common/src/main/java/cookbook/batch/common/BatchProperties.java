package cookbook.batch.common;

import java.util.LinkedHashMap;
import java.util.Map;
import org.springframework.boot.context.properties.ConfigurationProperties;

@ConfigurationProperties(prefix = "cookbook.batch", ignoreUnknownFields = false)
public record BatchProperties(Map<String, String> defaults, Map<String, JobSettings> jobs) {
    public BatchProperties {
        defaults = defaults == null ? Map.of() : Map.copyOf(defaults);
        jobs = jobs == null ? Map.of() : Map.copyOf(jobs);
    }

    public record JobSettings(Map<String, String> options, Map<String, Map<String, String>> files) {
        public JobSettings {
            options = options == null ? Map.of() : Map.copyOf(options);
            if (files == null) {
                files = Map.of();
            } else {
                Map<String, Map<String, String>> copied = new LinkedHashMap<>();
                files.forEach((file, properties) -> copied.put(file, Map.copyOf(properties)));
                files = Map.copyOf(copied);
            }
        }
    }

    public Map<String, String> resolve(BatchArguments args, String fileId) {
        Map<String, String> resolved = new LinkedHashMap<>(defaults);
        JobSettings job = jobs.get(args.job());
        if (job != null) {
            resolved.putAll(job.options());
            if (fileId != null) {
                resolved.putAll(job.files().getOrDefault(fileId, Map.of()));
            }
        }
        resolved.putAll(args.values());
        return Map.copyOf(resolved);
    }
}
