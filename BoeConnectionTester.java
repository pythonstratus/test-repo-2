package com.dstest.boe.tester;

import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.boot.CommandLineRunner;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.core.io.buffer.DataBuffer;
import org.springframework.core.io.buffer.DataBufferUtils;
import org.springframework.http.MediaType;
import org.springframework.http.client.reactive.ReactorClientHttpConnector;
import org.springframework.web.reactive.function.client.WebClient;
import org.springframework.web.reactive.function.client.WebClientResponseException;
import reactor.netty.http.client.HttpClient;

import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardOpenOption;
import java.time.Duration;
import java.util.Map;

@Slf4j
@SpringBootApplication
@RequiredArgsConstructor
public class BoeConnectionTester implements CommandLineRunner {

    private final BoeConfig boeConfig;

    public static void main(String[] args) {
        SpringApplication.run(BoeConnectionTester.class, args);
    }

    // ============================================================
    // Export format definitions
    // ============================================================
    public enum ExportFormat {
        PDF("application/pdf", "pdf"),
        CSV("text/csv", "csv"),
        XLSX("application/vnd.ms-excel", "xlsx");

        final String mimeType;
        final String extension;

        ExportFormat(String mimeType, String extension) {
            this.mimeType = mimeType;
            this.extension = extension;
        }
    }

    @Override
    public void run(String... args) {
        printBanner();
        log.info("Starting BOE Connection Test...");
        log.info("Target: {}", boeConfig.getBaseUrl());
        log.info("User:   {}", boeConfig.getUsername());
        log.info("Auth:   {}", boeConfig.getAuthType());
        System.out.println();

        WebClient webClient = buildWebClient();
        String logonToken = null;

        try {
            // ----- Step 1: Test basic reachability -----
            printStep(1, "Testing basic connectivity to " + boeConfig.getBaseUrl());
            testReachability(webClient);
            printResult(true, "Server is reachable");

            // ----- Step 2: Authenticate -----
            printStep(2, "Authenticating as '" + boeConfig.getUsername() + "' (auth=" + boeConfig.getAuthType() + ")");
            logonToken = login(webClient);
            printResult(true, "Authentication successful! Token received (length=" + logonToken.length() + ")");

            // ----- Step 3: Verify token works -----
            printStep(3, "Verifying token works (GET /infostore/cuid_6)");
            verifyToken(webClient, logonToken);
            printResult(true, "Authenticated API call successful");

            // ----- Step 4: List available Raylight connections -----
            printStep(4, "Listing available DB connections (GET /raylight/v1/connections)");
            String connectionsJson = listConnections(webClient, logonToken);
            printResult(true, "Raylight connections endpoint responded");
            log.info("Available connections response (first 500 chars):");
            System.out.println(connectionsJson.substring(0, Math.min(500, connectionsJson.length())));

            // ----- Step 5: Export a report -----
            // Replace with an id from your Step 4 listing. Example ids from your log:
            // 68534, 69408, 68254, 68150, 68689
            long docId = 68534L;
            printStep(5, "Exporting document " + docId + " as PDF and CSV");

            refreshDocument(webClient, logonToken, docId);

            Path pdfOut = Paths.get("report_" + docId + ".pdf");
            Path csvOut = Paths.get("report_" + docId + ".csv");

            exportDocument(webClient, logonToken, docId, ExportFormat.PDF, pdfOut);
            exportDocument(webClient, logonToken, docId, ExportFormat.CSV, csvOut);

            printResult(true, "Exports complete: " + pdfOut.toAbsolutePath() + ", " + csvOut.toAbsolutePath());

            System.out.println();
            System.out.println("================================================================");
            System.out.println("  ALL TESTS PASSED - BOE connection is working!");
            System.out.println("================================================================");

        } catch (WebClientResponseException e) {
            printResult(false, "HTTP " + e.getStatusCode() + " - " + e.getResponseBodyAsString());
            log.error("Connection test FAILED", e);
        } catch (Exception e) {
            printResult(false, e.getMessage());
            log.error("Connection test FAILED", e);
        } finally {
            if (logonToken != null) {
                logout(webClient, logonToken);
            }
        }
    }

    // ============================================================
    // WebClient builder
    // ============================================================
    private WebClient buildWebClient() {
        HttpClient httpClient = HttpClient.create()
                .responseTimeout(Duration.ofSeconds(boeConfig.getReadTimeout()));

        return WebClient.builder()
                .baseUrl(boeConfig.getBaseUrl())
                .clientConnector(new ReactorClientHttpConnector(httpClient))
                .codecs(c -> c.defaultCodecs().maxInMemorySize(50 * 1024 * 1024))
                .build();
    }

    // ============================================================
    // Step 1: Reachability
    // ============================================================
    private void testReachability(WebClient webClient) {
        webClient.get()
                .uri("/logon/long")
                .retrieve()
                .toBodilessEntity()
                .timeout(Duration.ofSeconds(boeConfig.getConnectTimeout()))
                .block();
    }

    // ============================================================
    // Step 2: Login
    // ============================================================
    private String login(WebClient webClient) {
        Map<String, String> payload = Map.of(
                "userName", boeConfig.getUsername(),
                "password", boeConfig.getPassword(),
                "auth", boeConfig.getAuthType()
        );

        Map<String, Object> response = webClient.post()
                .uri("/logon/long")
                .contentType(MediaType.APPLICATION_JSON)
                .accept(MediaType.APPLICATION_JSON)
                .bodyValue(payload)
                .retrieve()
                .bodyToMono(Map.class)
                .timeout(Duration.ofSeconds(boeConfig.getReadTimeout()))
                .block();

        if (response == null || !response.containsKey("logonToken")) {
            throw new RuntimeException("Login response missing logonToken: " + response);
        }
        return (String) response.get("logonToken");
    }

    // ============================================================
    // Step 3: Verify token
    // ============================================================
    private void verifyToken(WebClient webClient, String logonToken) {
        webClient.get()
                .uri("/infostore/cuid_6")
                .header("X-SAP-LogonToken", logonToken)
                .accept(MediaType.APPLICATION_JSON)
                .retrieve()
                .bodyToMono(String.class)
                .timeout(Duration.ofSeconds(boeConfig.getReadTimeout()))
                .block();
    }

    // ============================================================
    // Step 4: List Raylight connections
    // ============================================================
    private String listConnections(WebClient webClient, String logonToken) {
        return webClient.get()
                .uri("/raylight/v1/connections")
                .header("X-SAP-LogonToken", logonToken)
                .accept(MediaType.APPLICATION_JSON)
                .retrieve()
                .bodyToMono(String.class)
                .timeout(Duration.ofSeconds(boeConfig.getReadTimeout()))
                .block();
    }

    // ============================================================
    // Step 5a: Refresh document
    // ============================================================
    private void refreshDocument(WebClient webClient, String logonToken, long docId) {
        log.info("Refreshing document {}", docId);
        webClient.get()
                .uri("/raylight/v1/documents/{docId}/parameters", docId)
                .header("X-SAP-LogonToken", logonToken)
                .accept(MediaType.APPLICATION_JSON)
                .retrieve()
                .bodyToMono(String.class)
                .timeout(Duration.ofMinutes(2))
                .block();
        log.info("Refresh complete for document {}", docId);
    }

    // ============================================================
    // Step 5b: Export document to PDF / CSV / XLSX
    // ============================================================
    private void exportDocument(WebClient webClient, String logonToken, long docId,
                                ExportFormat format, Path outputPath) {
        log.info("Exporting document {} as {} to {}", docId, format, outputPath);

        DataBufferUtils.write(
                        webClient.get()
                                .uri("/raylight/v1/documents/{docId}", docId)
                                .header("X-SAP-LogonToken", logonToken)
                                .header("Accept", format.mimeType)
                                .retrieve()
                                .bodyToFlux(DataBuffer.class),
                        outputPath,
                        StandardOpenOption.CREATE,
                        StandardOpenOption.TRUNCATE_EXISTING,
                        StandardOpenOption.WRITE)
                .block(Duration.ofMinutes(10));

        log.info("Wrote {} bytes to {}", outputPath.toFile().length(), outputPath.toAbsolutePath());
    }

    // ============================================================
    // Logout
    // ============================================================
    private void logout(WebClient webClient, String logonToken) {
        try {
            webClient.post()
                    .uri("/logoff")
                    .header("X-SAP-LogonToken", logonToken)
                    .retrieve()
                    .toBodilessEntity()
                    .timeout(Duration.ofSeconds(10))
                    .block();
            log.info("Logged out successfully");
        } catch (Exception e) {
            log.warn("Logout failed (non-fatal): {}", e.getMessage());
        }
    }

    // ============================================================
    // Console helpers
    // ============================================================
    private void printBanner() {
        System.out.println("================================================================");
        System.out.println("        BOE Connection Tester v1.0");
        System.out.println("================================================================");
    }

    private void printStep(int stepNum, String description) {
        System.out.println("[Step " + stepNum + "] " + description);
    }

    private void printResult(boolean pass, String message) {
        System.out.println("   " + (pass ? "PASS" : "FAIL") + ": " + message);
    }
}
