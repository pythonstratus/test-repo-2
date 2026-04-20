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
            printStep(3, "Verifying token works");
            verifyToken(webClient, logonToken);
            printResult(true, "Authenticated API call successful");

            // ----- Step 4: List available Raylight connections -----
            printStep(4, "Listing available DB connections (GET /raylight/v1/connections)");
            String connectionsXml = listConnections(webClient, logonToken);
            printResult(true, "Raylight connections endpoint responded");
            log.info("Available connections response (first 500 chars):");
            System.out.println(connectionsXml.substring(0, Math.min(500, connectionsXml.length())));

            // ----- Step 5: Export a report -----
            // Replace with an actual document id from /raylight/v1/documents
            long docId = 6408483L;
            printStep(5, "Exporting document " + docId + " as PDF and CSV");

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
                .responseTimeout(Duration.ofMinutes(15));

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
    // Step 2: Login (XML payload + XML response)
    // ============================================================
    private String login(WebClient webClient) {
        String xmlPayload = String.format(
                "<attrs xmlns=\"http://www.sap.com/rws/bip\">" +
                    "<attr name=\"userName\" type=\"string\">%s</attr>" +
                    "<attr name=\"password\" type=\"string\">%s</attr>" +
                    "<attr name=\"auth\" type=\"string\" " +
                        "possibilities=\"secEnterprise,secLDAP,secWinAD,secSAPR3\">%s</attr>" +
                "</attrs>",
                escapeXml(boeConfig.getUsername()),
                escapeXml(boeConfig.getPassword()),
                escapeXml(boeConfig.getAuthType())
        );

        String response = webClient.post()
                .uri("/logon/long")
                .contentType(MediaType.APPLICATION_XML)
                .accept(MediaType.APPLICATION_XML)
                .bodyValue(xmlPayload)
                .retrieve()
                .bodyToMono(String.class)
                .timeout(Duration.ofSeconds(boeConfig.getReadTimeout()))
                .block();

        if (response == null) {
            throw new RuntimeException("Login response was null");
        }

        // Parse token from XML response: <logonToken>...</logonToken>
        int startTag = response.indexOf("<logonToken>");
        int endTag = response.indexOf("</logonToken>");
        if (startTag < 0 || endTag < 0) {
            throw new RuntimeException("Login response missing <logonToken>: " + response);
        }
        return response.substring(startTag + "<logonToken>".length(), endTag);
    }

    // ============================================================
    // Step 3: Verify token (using /logon/long - stable endpoint)
    // ============================================================
    private void verifyToken(WebClient webClient, String logonToken) {
        webClient.get()
                .uri("/logon/long")
                .header("X-SAP-LogonToken", logonToken)
                .accept(MediaType.APPLICATION_XML)
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
                .accept(MediaType.APPLICATION_XML)
                .retrieve()
                .bodyToMono(String.class)
                .timeout(Duration.ofSeconds(boeConfig.getReadTimeout()))
                .block();
    }

    // ============================================================
    // Step 5: Export document to PDF / CSV / XLSX
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
                    .accept(MediaType.APPLICATION_XML)
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
    // Helpers
    // ============================================================
    private String escapeXml(String s) {
        if (s == null) return "";
        return s.replace("&", "&amp;")
                .replace("<", "&lt;")
                .replace(">", "&gt;")
                .replace("\"", "&quot;")
                .replace("'", "&apos;");
    }

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
