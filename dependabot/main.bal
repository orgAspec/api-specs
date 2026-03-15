// Copyright (c) 2026, WSO2 LLC. (http://www.wso2.com).
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import ballerina/crypto;
import ballerina/data.jsondata;
import ballerina/data.yaml;
import ballerina/file;
import ballerinax/github;
import ballerina/http;
import ballerina/io;
import ballerina/lang.regexp;
import ballerina/os;
import ballerina/time;

// Logging utility function for structured output
isolated function print(string message, string level, int indentation) {
    string spaces = string:'join("", from int i in 0 ..< indentation select "\t");
    io:println(string `${spaces}[${level}] ${message}`);
}

// Versioning strategy types
const RELEASE_TAG_BASED = "release-tag-based";
const FILE_BASED = "file-based";

// Supported check frequencies
const FREQ_DAILY = "daily";
const FREQ_WEEKLY = "weekly";
const FREQ_MONTHLY = "monthly";
const FREQ_QUARTERLY = "quarterly";

// Resolution record type
type Resolution record {|
    string parentDirectory;
    string strategy;
|};

// Spec metadata entry record type
type SpecEntry record {|
    string identifier;
    string lastSnapshot;
    string specPath;
    string documentationUrl;
    string? branch = ();
    string? connectorRepo = ();
    string? lastContentHash = ();
    // How often this spec should be checked.
    // Accepted values: "daily" | "weekly" | "monthly" | "quarterly"
    // Defaults to "daily" when the field is absent or empty.
    string frequency = FREQ_DAILY;
    // ISO-8601 date string (YYYY-MM-DD) of the last time this spec was
    // checked (regardless of whether an update was found).
    // An empty string means the spec has never been checked, so it is
    // always considered due.
    string lastChecked = "";
    Resolution resolution;
|};

// Root config record type
type SpecMetadataConfig record {|
    SpecEntry[] specMetadata;
|};

// Update result record
type UpdateResult record {|
    string identifier;
    SpecEntry spec;
    string oldSnapshot;
    string newSnapshot;
    string apiVersion;
    string downloadUrl;
    string localPath;
    boolean contentChanged;
    string updateType;
    string folderPath;
|};

// File info record for file-based strategy
type FileInfo record {|
    string path;
    string version;
    int versionNum;
    int rolloutNum;
|};

// Bash script result record
type BashScriptResult record {
    string filePath;
    string apiVersion;
    string lastCommitDate;
};

// ---------------------------------------------------------------------------
// Frequency / scheduling helpers
// ---------------------------------------------------------------------------

// Return the minimum number of days that must have elapsed since lastChecked
// before the spec is considered due for another check.
function frequencyToDays(string frequency) returns int {
    match frequency {
        FREQ_DAILY => { return 1; }
        FREQ_WEEKLY => { return 7; }
        FREQ_MONTHLY => { return 30; }
        FREQ_QUARTERLY => { return 90; }
        _ => {
            print(string `Unknown frequency '${frequency}', defaulting to daily`, "Warn", 1);
            return 1;
        }
    }
}

// Return today's date as a YYYY-MM-DD string using UTC civil time.
function todayString() returns string {
    time:Utc now = time:utcNow();
    time:Civil civil = time:utcToCivil(now);
    string month = civil.month < 10 ? string `0${civil.month}` : civil.month.toString();
    string day   = civil.day   < 10 ? string `0${civil.day}`   : civil.day.toString();
    return string `${civil.year}-${month}-${day}`;
}

// Parse a YYYY-MM-DD string into a time:Civil value.
// Returns an error for blank or malformed strings.
function parseDateString(string dateStr) returns time:Civil|error {
    if dateStr.trim() == "" {
        return error("empty date string");
    }
    string[] parts = regexp:split(re `-`, dateStr.trim());
    if parts.length() != 3 {
        return error(string `Invalid date format: ${dateStr}`);
    }
    int|error year  = int:fromString(parts[0]);
    int|error month = int:fromString(parts[1]);
    int|error day   = int:fromString(parts[2]);
    if year is error || month is error || day is error {
        return error(string `Non-numeric date components in: ${dateStr}`);
    }
    return {
        year:  year,
        month: month,
        day:   day,
        hour:  0,
        minute: 0,
        second: 0
    };
}

// Convert a time:Civil (date-only) value to a Unix-epoch day count.
// Accurate for dates in the range 1970-01-01 … 2099-12-31.
function civilToEpochDays(time:Civil civil) returns int {
    // Use Ballerina's time module to get a UTC epoch (seconds) for midnight on
    // this date, then convert to days.
    time:Civil midnight = {
        year:   civil.year,
        month:  civil.month,
        day:    civil.day,
        hour:   0,
        minute: 0,
        second: 0
    };
    time:Utc|error utc = time:utcFromCivil(midnight);
    if utc is error {
        return 0;
    }
    // utc[0] is the seconds component of the epoch tuple
    return (utc[0] / 86400).abs();
}

// Decide whether a spec is due for a check.
//
// A spec is due when:
//   • lastChecked is blank (never been checked), OR
//   • the number of whole days since lastChecked >= frequencyToDays(frequency)
function isDue(string lastChecked, string frequency) returns boolean {
    time:Civil|error lastDate = parseDateString(lastChecked);
    if lastDate is error {
        // Never been checked — always due.
        return true;
    }

    string todayStr = todayString();
    time:Civil|error todayCivil = parseDateString(todayStr);
    if todayCivil is error {
        // Should never happen; default to due so we don't silently skip.
        return true;
    }

    int lastDays  = civilToEpochDays(lastDate);
    int todayDays = civilToEpochDays(todayCivil);
    int elapsed   = todayDays - lastDays;
    int threshold = frequencyToDays(frequency);

    return elapsed >= threshold;
}

// ---------------------------------------------------------------------------
// Existing helpers (unchanged)
// ---------------------------------------------------------------------------

// Check for version updates
function hasVersionChanged(string oldSnapshot, string newSnapshot) returns boolean {
    return oldSnapshot != newSnapshot;
}

// Check for content updates
function hasContentChanged(string? oldHash, string newHash) returns boolean {
    if oldHash is () || oldHash == "" {
        return true;
    }
    return oldHash != newHash;
}

// Calculate SHA-256 hash of content
function calculateHash(string content) returns string {
    byte[] contentBytes = content.toBytes();
    byte[] hashBytes = crypto:hashSha256(contentBytes);
    return hashBytes.toBase16();
}

// Parse GitHub URL to extract owner, repo, branch, and path
function parseGitHubUrl(string url) returns [string, string, string, string]|error {
    string cleanUrl = url;
    if cleanUrl.startsWith("https://github.com/") {
        cleanUrl = cleanUrl.substring(19);
    } else {
        return error("Invalid GitHub URL format");
    }

    string[] parts = regexp:split(re `/`, cleanUrl);
    if parts.length() < 2 {
        return error("Invalid GitHub URL: missing owner/repo");
    }

    string owner = parts[0];
    string repo = parts[1];
    string branch = "main";
    string path = "";

    if parts.length() > 3 && parts[2] == "tree" {
        branch = parts[3];
        if parts.length() > 4 {
            path = string:'join("/", ...parts.slice(4));
        }
    }

    return [owner, repo, branch, path];
}

// Remove quotes from string
function removeQuotes(string s) returns string {
    return re `"|'`.replace(s, "");
}

// Regex-based version extraction as fallback
function extractApiVersionWithRegex(string content) returns string|error {
    print("Using regex-based version extraction", "Info", 2);

    string[] lines = regexp:split(re `\n`, content);
    boolean inInfoSection = false;

    foreach string line in lines {
        string trimmedLine = line.trim();

        if trimmedLine.startsWith("\"version\":") || trimmedLine.startsWith("'version':") {
            string[] parts = regexp:split(re `:`, trimmedLine);
            if parts.length() >= 2 {
                string versionValue = parts[1].trim();
                versionValue = removeQuotes(versionValue);
                versionValue = regexp:replace(re `,`, versionValue, "").trim();
                if versionValue.length() > 0 {
                    print(string `Extracted version via regex (JSON): ${versionValue}`, "Info", 2);
                    return versionValue;
                }
            }
        }

        if trimmedLine == "info:" {
            inInfoSection = true;
            continue;
        }

        if inInfoSection {
            if !line.startsWith(" ") && !line.startsWith("\t") && trimmedLine != "" && !trimmedLine.startsWith("#") {
                break;
            }

            if trimmedLine.startsWith("version:") {
                string[] parts = regexp:split(re `:`, trimmedLine);
                if parts.length() >= 2 {
                    string versionValue = parts[1].trim();
                    versionValue = removeQuotes(versionValue);
                    print(string `Extracted version via regex (YAML): ${versionValue}`, "Info", 2);
                    return versionValue;
                }
            }
        }
    }

    return error("Could not extract API version from spec using regex");
}

// Extract version from OpenAPI spec using proper YAML/JSON parsing with regex fallback
function extractApiVersion(string content) returns string|error {
    string trimmedContent = content.trim();
    boolean isJson = trimmedContent.startsWith("{") || trimmedContent.startsWith("[");

    json parsedData = {};

    if isJson {
        json|error jsonResult = jsondata:parseString(content);
        if jsonResult is error {
            print(string `JSON parsing failed: ${jsonResult.message()}, falling back to regex`, "Warn", 2);
            return extractApiVersionWithRegex(content);
        }
        parsedData = jsonResult;
    } else {
        json|error yamlResult = yaml:parseString(content);
        if yamlResult is error {
            print(string `YAML parsing failed: ${yamlResult.message()}, falling back to regex`, "Warn", 2);
            return extractApiVersionWithRegex(content);
        }
        parsedData = yamlResult;
    }

    if parsedData is map<json> {
        json? infoField = parsedData["info"];
        if infoField is () {
            print("'info' field not found in parsed spec, falling back to regex", "Warn", 2);
            return extractApiVersionWithRegex(content);
        }

        if infoField is map<json> {
            json? versionField = infoField["version"];
            if versionField is () {
                print("'version' field not found under 'info', falling back to regex", "Warn", 2);
                return extractApiVersionWithRegex(content);
            }

            if versionField is string {
                print(string `Extracted version via YAML/JSON parsing: ${versionField}`, "Info", 2);
                return versionField;
            } else {
                print("'version' field is not a string, falling back to regex", "Warn", 2);
                return extractApiVersionWithRegex(content);
            }
        } else {
            print("'info' field is not a map, falling back to regex", "Warn", 2);
            return extractApiVersionWithRegex(content);
        }
    } else {
        print("Parsed data is not a map, falling back to regex", "Warn", 2);
        return extractApiVersionWithRegex(content);
    }
}

// Helper: extract text content from HTTP response
isolated function getTextFromResponse(http:Response response) returns string|error {
    string|byte[]|error content = response.getTextPayload();
    if content is error {
        return error("Failed to get content from response");
    }
    if content is string {
        return content;
    }
    return check string:fromBytes(content);
}

// Detect file extension from content format
function getFileExtension(string content) returns string {
    string trimmedContent = content.trim();
    boolean isJson = trimmedContent.startsWith("{") || trimmedContent.startsWith("[");
    return isJson ? "json" : "yaml";
}

// Check if a spec file already exists in the directory (either .json or .yaml)
function specFileExists(string dirPath) returns boolean|error {
    if !check file:test(dirPath, file:EXISTS) {
        return false;
    }

    string jsonPath = dirPath + "/openapi.json";
    string yamlPath = dirPath + "/openapi.yaml";

    boolean jsonExists = check file:test(jsonPath, file:EXISTS);
    boolean yamlExists = check file:test(yamlPath, file:EXISTS);

    return jsonExists || yamlExists;
}

// Save spec to file - preserves original format (JSON or YAML)
function saveSpec(string content, string localPath) returns error? {
    string dirPath = check file:parentPath(localPath);
    if !check file:test(dirPath, file:EXISTS) {
        check file:createDir(dirPath, file:RECURSIVE);
    }

    check io:fileWriteString(localPath, content);
    print(string `Saved to ${localPath}`, "Info", 1);
    return;
}

// Download raw file from GitHub
function downloadRawFile(string owner, string repo, string branch, string filePath) returns string|error {
    string baseUrl = "https://raw.githubusercontent.com";
    string path = string `/${owner}/${repo}/${branch}/${filePath}`;
    print(string `Downloading from raw GitHub URL: ${baseUrl}${path}`, "Info", 1);

    http:Client httpClient = check new (baseUrl);
    http:Response response = check httpClient->get(path);

    if response.statusCode != 200 {
        return error(string `Failed to download: HTTP ${response.statusCode} from ${baseUrl}${path}`);
    }

    return check getTextFromResponse(response);
}

// List GitHub directory contents recursively using GitHub API
function listGitHubDirectoryRecursive(string owner, string repo, string branch, string path, string token) returns string[]|error {
    print(string `Listing directory: ${path}`, "Info", 2);

    string baseUrl = "https://api.github.com";
    string apiPath = string `/repos/${owner}/${repo}/contents/${path}?ref=${branch}`;

    http:Client httpClient = check new (baseUrl);
    map<string> headers = {
        "Authorization": string `Bearer ${token}`,
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28"
    };

    http:Response response = check httpClient->get(apiPath, headers);

    if response.statusCode != 200 {
        return error(string `Failed to list directory: HTTP ${response.statusCode}`);
    }

    json|error content = response.getJsonPayload();
    if content is error {
        return error("Failed to parse directory listing");
    }

    string[] allFiles = [];

    if content is json[] {
        foreach json item in content {
            if item is map<json> {
                json? itemType = item["type"];
                json? itemPath = item["path"];

                if itemType is string && itemPath is string {
                    if itemType == "file" {
                        allFiles.push(itemPath);
                    } else if itemType == "dir" {
                        string[]|error subFiles = listGitHubDirectoryRecursive(owner, repo, branch, itemPath, token);
                        if subFiles is string[] {
                            foreach string subFile in subFiles {
                                allFiles.push(subFile);
                            }
                        }
                    }
                }
            }
        }
        return allFiles;
    }

    return error("Unexpected response format from GitHub API");
}

// Find the best matching file - prefer YAML over JSON when multiple matches
function findBestMatchingFile(string[] files, string specPathRegex) returns string|error {
    print(string `Finding best match for regex: ${specPathRegex}`, "Info", 2);
    print(string `Total files to search: ${files.length()}`, "Info", 2);

    string? bestFile = ();

    regexp:RegExp pattern = check regexp:fromString(specPathRegex);

    foreach string filePath in files {
        string[] pathParts = regexp:split(re `/`, filePath);
        string fileName = pathParts[pathParts.length() - 1];

        if fileName.includes("Collection") {
            continue;
        }

        boolean matches = pattern.isFullMatch(fileName);

        if matches {
            print(string `Match: ${filePath}`, "Info", 3);

            if bestFile is () {
                bestFile = filePath;
            } else {
                boolean currentIsYaml = fileName.endsWith(".yaml") || fileName.endsWith(".yml");
                string[] bestPathParts = regexp:split(re `/`, bestFile);
                string bestFileName = bestPathParts[bestPathParts.length() - 1];
                boolean bestIsYaml = bestFileName.endsWith(".yaml") || bestFileName.endsWith(".yml");

                if currentIsYaml && !bestIsYaml {
                    bestFile = filePath;
                }
            }
        }
    }

    if bestFile is string {
        print(string `Best match: ${bestFile}`, "Info", 2);
        return bestFile;
    }

    return error("No matching files found");
}

// ---------------------------------------------------------------------------
// Strategy processors (unchanged logic, just receive the already-resolved spec)
// ---------------------------------------------------------------------------

// Process repository with release-tag based strategy
function processReleaseTagRepo(github:Client githubClient, SpecEntry spec, string token) returns UpdateResult|error? {
    print(string `Checking: ${spec.identifier} [Release-Tag Strategy]`, "Info", 0);

    [string, string, string, string]|error urlParts = parseGitHubUrl(spec.resolution.parentDirectory);
    if urlParts is error {
        print(string `Failed to parse URL: ${urlParts.message()}`, "Error", 1);
        return urlParts;
    }

    var [owner, repo, _, basePath] = urlParts;

    github:Release|error latestRelease = githubClient->/repos/[owner]/[repo]/releases/latest();

    if latestRelease is error {
        string errorMsg = latestRelease.message();
        if errorMsg.includes("404") {
            print(string `No releases found for ${owner}/${repo}`, "Error", 1);
        } else if errorMsg.includes("401") || errorMsg.includes("403") {
            print("Authentication failed", "Error", 1);
        } else {
            print(string `Error: ${errorMsg}`, "Error", 1);
        }
        return latestRelease;
    }

    string tagName = latestRelease.tag_name;
    string? publishedAt = latestRelease.published_at;

    if latestRelease.prerelease || latestRelease.draft {
        print(string `Skipping pre-release: ${tagName}`, "Info", 1);
        return ();
    }

    print(string `Latest release tag: ${tagName}`, "Info", 1);
    if publishedAt is string {
        print(string `Published: ${publishedAt}`, "Info", 1);
    }

    print(string `Listing files in ${basePath} to find spec matching pattern: ${spec.specPath}`, "Info", 1);

    string[]|error allFiles = listGitHubDirectoryRecursive(owner, repo, tagName, basePath, token);
    if allFiles is error {
        print(string `Failed to list files: ${allFiles.message()}`, "Error", 1);
        return allFiles;
    }

    string|error bestFileResult = findBestMatchingFile(allFiles, spec.specPath);
    if bestFileResult is error {
        print(string `No matching spec file found: ${bestFileResult.message()}`, "Error", 1);
        return bestFileResult;
    }

    string specFilePath = bestFileResult;
    print(string `Selected spec file: ${specFilePath}`, "Info", 1);

    string|error specContent = downloadRawFile(owner, repo, tagName, specFilePath);
    if specContent is error {
        print("Download failed: " + specContent.message(), "Error", 1);
        return specContent;
    }

    boolean versionChanged = hasVersionChanged(spec.lastSnapshot, tagName);
    string contentHash = calculateHash(specContent);
    boolean contentChanged = hasContentChanged(spec.lastContentHash, contentHash);

    print(string `Content Hash: ${contentHash.substring(0, 16)}...`, "Info", 1);

    if !versionChanged && !contentChanged {
        print(string `No updates (snapshot: ${spec.lastSnapshot}, content unchanged)`, "Info", 1);
        return ();
    }

    string updateType = versionChanged && contentChanged ? "both" : (versionChanged ? "version" : "content");
    print(string `UPDATE DETECTED! (Type: ${updateType})`, "Info", 1);

    string|error apiVersionResult = extractApiVersion(specContent);
    string apiVersion = apiVersionResult is string ? apiVersionResult :
        (tagName.startsWith("v") ? tagName.substring(1) : tagName);

    print(string `API Version: ${apiVersion}`, "Info", 1);

    string[] identifierParts = regexp:split(re `\.`, spec.identifier);
    string directoryPath = "";
    if identifierParts.length() >= 2 {
        string vendor = identifierParts[0];
        string api = string:'join(".", ...identifierParts.slice(1));
        directoryPath = vendor + "/" + api;
    } else {
        directoryPath = spec.identifier;
    }

    string versionDir = "../openapi/" + directoryPath + "/" + apiVersion;

    if !versionChanged || !contentChanged {
        print(string `Skipping update - need both version and content to change (version changed: ${versionChanged}, content changed: ${contentChanged})`, "Info", 1);
        return ();
    }

    string fileExtension = getFileExtension(specContent);
    string localPath = versionDir + "/openapi." + fileExtension;

    if check file:test(versionDir, file:EXISTS) {
        string jsonPath = versionDir + "/openapi.json";
        string yamlPath = versionDir + "/openapi.yaml";

        if check file:test(jsonPath, file:EXISTS) {
            check file:remove(jsonPath);
            print("Removed existing openapi.json", "Info", 2);
        }
        if check file:test(yamlPath, file:EXISTS) {
            check file:remove(yamlPath);
            print("Removed existing openapi.yaml", "Info", 2);
        }
    }

    error? saveResult = saveSpec(specContent, localPath);
    if saveResult is error {
        print("Save failed: " + saveResult.message(), "Error", 1);
        return saveResult;
    }

    string oldSnapshot = spec.lastSnapshot;
    spec.lastSnapshot = tagName;
    spec.lastContentHash = contentHash;

    string folderPath = "openapi/" + directoryPath + "/" + apiVersion;

    return {
        identifier: spec.identifier,
        spec: spec,
        oldSnapshot: oldSnapshot,
        newSnapshot: tagName,
        apiVersion: apiVersion,
        downloadUrl: string `https://github.com/${owner}/${repo}/releases/tag/${tagName}`,
        localPath: localPath,
        contentChanged: contentChanged,
        updateType: updateType,
        folderPath: folderPath
    };
}

// Process repository with file-based strategy (uses bash script to clone and find spec)
function processFileBasedRepo(SpecEntry spec, string token) returns UpdateResult|error? {
    print(string `Checking: ${spec.identifier} [File-Based Strategy]`, "Info", 0);

    [string, string, string, string]|error urlParts = parseGitHubUrl(spec.resolution.parentDirectory);
    if urlParts is error {
        print(string `Failed to parse URL: ${urlParts.message()}`, "Error", 1);
        return urlParts;
    }

    var [owner, repo, branch, basePath] = urlParts;

    string actualBranch = spec.branch is string ? <string>spec.branch : branch;

    print(string `Repository: ${owner}/${repo}`, "Info", 1);
    print(string `Branch: ${actualBranch}`, "Info", 1);
    print(string `Base path: ${basePath}`, "Info", 1);
    print(string `Spec pattern: ${spec.specPath}`, "Info", 1);

    string repoUrl = string `https://github.com/${owner}/${repo}.git`;

    print("Running bash script to clone and find latest spec...", "Info", 1);

    string scriptPath = "./find_latest_spec.sh";

    os:Process|error result = os:exec(
        {value: scriptPath, arguments: [repoUrl, actualBranch, basePath, spec.specPath]}
    );

    if result is error {
        print(string `Failed to execute bash script: ${result.message()}`, "Error", 1);
        return result;
    }

    os:Process process = result;

    int exitCode = check process.waitForExit();

    if exitCode != 0 {
        print(string `Bash script failed with exit code ${exitCode}`, "Error", 1);
        return error(string `Bash script exited with code ${exitCode}`);
    }

    byte[]|error outputBytes = process.output();
    if outputBytes is error {
        print(string `Failed to get output: ${outputBytes.message()}`, "Error", 1);
        return outputBytes;
    }

    string output = check string:fromBytes(outputBytes);
    print(string `Bash script output: ${output}`, "Info", 2);

    json|error jsonResult = jsondata:parseString(output);
    if jsonResult is error {
        print(string `Failed to parse bash script output: ${jsonResult.message()}`, "Error", 1);
        return jsonResult;
    }

    BashScriptResult scriptResult = check jsonResult.cloneWithType();

    print(string `Selected file: ${scriptResult.filePath}`, "Info", 1);
    print(string `API Version: ${scriptResult.apiVersion}`, "Info", 1);
    print(string `Last commit date: ${scriptResult.lastCommitDate}`, "Info", 1);

    string|error specContent = downloadRawFile(owner, repo, actualBranch, scriptResult.filePath);

    if specContent is error {
        print("Download failed: " + specContent.message(), "Error", 1);
        return specContent;
    }

    string contentHash = calculateHash(specContent);
    boolean contentChanged = hasContentChanged(spec.lastContentHash, contentHash);

    print(string `Content Hash: ${contentHash.substring(0, 16)}...`, "Info", 1);

    string apiVersion = scriptResult.apiVersion;

    string newSnapshot = scriptResult.lastCommitDate;

    boolean snapshotChanged = hasVersionChanged(spec.lastSnapshot, newSnapshot);

    if !snapshotChanged || !contentChanged {
        print(string `No updates - need both commit date and content to change (commit date changed: ${snapshotChanged}, content changed: ${contentChanged})`, "Info", 1);
        return ();
    }

    string updateType = "both";
    print(string `UPDATE DETECTED! (${spec.lastSnapshot} -> ${newSnapshot}, Type: ${updateType})`, "Info", 1);

    string[] identifierParts = regexp:split(re `\.`, spec.identifier);
    string directoryPath = "";
    if identifierParts.length() >= 2 {
        string vendor = identifierParts[0];
        string api = string:'join(".", ...identifierParts.slice(1));
        directoryPath = vendor + "/" + api;
    } else {
        directoryPath = spec.identifier;
    }

    string versionDir = "../openapi/" + directoryPath + "/" + apiVersion;

    string fileExtension = getFileExtension(specContent);
    string localPath = versionDir + "/openapi." + fileExtension;

    if check file:test(versionDir, file:EXISTS) {
        string jsonPath = versionDir + "/openapi.json";
        string yamlPath = versionDir + "/openapi.yaml";

        if check file:test(jsonPath, file:EXISTS) {
            check file:remove(jsonPath);
            print("Removed existing openapi.json", "Info", 2);
        }
        if check file:test(yamlPath, file:EXISTS) {
            check file:remove(yamlPath);
            print("Removed existing openapi.yaml", "Info", 2);
        }
    }

    error? saveResult = saveSpec(specContent, localPath);
    if saveResult is error {
        print("Save failed: " + saveResult.message(), "Error", 1);
        return saveResult;
    }

    string oldSnapshot = spec.lastSnapshot;
    spec.lastSnapshot = newSnapshot;
    spec.lastContentHash = contentHash;

    string folderPath = "openapi/" + directoryPath + "/" + apiVersion;

    return {
        identifier: spec.identifier,
        spec: spec,
        oldSnapshot: oldSnapshot,
        newSnapshot: newSnapshot,
        apiVersion: apiVersion,
        downloadUrl: string `https://github.com/${owner}/${repo}/blob/${actualBranch}/${scriptResult.filePath}`,
        localPath: localPath,
        contentChanged: contentChanged,
        updateType: updateType,
        folderPath: folderPath
    };
}

// Write repos.json with the new structure
function writeReposJson(SpecMetadataConfig config) returns error? {
    json configJson = config.toJson();
    string formattedJson = configJson.toJsonString();
    check io:fileWriteString("../repos.json", formattedJson);
    return;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

public function main() returns error? {
    print("=== Dependabot OpenAPI Monitor ===", "Info", 0);
    print("Starting OpenAPI specification monitoring...", "Info", 0);

    string today = todayString();
    print(string `Today: ${today}`, "Info", 0);

    // Get GitHub token
    string? ghToken = os:getEnv("GH_TOKEN");
    string? ballerinaToken = os:getEnv("BALLERINA_BOT_TOKEN");
    string? githubToken = os:getEnv("GITHUB_TOKEN");

    string token = "";
    if ghToken is string && ghToken.length() > 0 {
        token = ghToken;
    } else if ballerinaToken is string && ballerinaToken.length() > 0 {
        token = ballerinaToken;
    } else if githubToken is string && githubToken.length() > 0 {
        token = githubToken;
    }

    if token.length() == 0 {
        print("GitHub token not found. Please set one of: GH_TOKEN, BALLERINA_BOT_TOKEN, or GITHUB_TOKEN", "Error", 0);
        return;
    }

    // Initialize GitHub client
    github:Client githubClient = check new ({
        auth: {
            token: token
        }
    });

    // Load configuration from repos.json
    json reposJson = check io:fileReadJson("../repos.json");
    SpecMetadataConfig config = check reposJson.cloneWithType();

    print(string `Found ${config.specMetadata.length()} specifications to monitor.`, "Info", 0);
    io:println("");

    // Track updates
    UpdateResult[] updates = [];

    // Check each specification based on frequency, then strategy
    foreach int i in 0 ..< config.specMetadata.length() {
        SpecEntry spec = config.specMetadata[i];

        // -----------------------------------------------------------------
        // Frequency gate: skip this spec if it is not due yet
        // -----------------------------------------------------------------
        string effectiveFrequency = spec.frequency == "" ? FREQ_DAILY : spec.frequency;
        boolean due = isDue(spec.lastChecked, effectiveFrequency);

        if !due {
            print(
                string `Skipping ${spec.identifier} (frequency: ${effectiveFrequency}, last checked: ${spec.lastChecked})`,
                "Info", 0
            );
            io:println("");
            continue;
        }

        print(
            string `Due for check — ${spec.identifier} (frequency: ${effectiveFrequency}, last checked: ${spec.lastChecked == "" ? "never" : spec.lastChecked})`,
            "Info", 0
        );

        // -----------------------------------------------------------------
        // Process the spec using its configured strategy
        // -----------------------------------------------------------------
        UpdateResult|error? result = ();

        if spec.resolution.strategy == RELEASE_TAG_BASED {
            result = processReleaseTagRepo(githubClient, spec, token);
        } else if spec.resolution.strategy == FILE_BASED {
            result = processFileBasedRepo(spec, token);
        } else {
            print(string `Unknown strategy: ${spec.resolution.strategy}`, "Warn", 0);
        }

        // -----------------------------------------------------------------
        // Always update lastChecked (whether or not an update was found)
        // -----------------------------------------------------------------
        spec.lastChecked = today;

        if result is UpdateResult {
            updates.push(result);
            // Propagate all mutations (lastSnapshot, lastContentHash, lastChecked)
            // back into the config array so they are persisted to repos.json.
            result.spec.lastChecked = today;
            config.specMetadata[i] = result.spec;
        } else {
            // No update found, but we still need to save the new lastChecked.
            config.specMetadata[i] = spec;
        }

        io:println("");
    }

    // Report updates
    if updates.length() > 0 {
        io:println("");
        print(string `Found ${updates.length()} updates:`, "Info", 0);
        io:println("");

        string[] updateSummary = [];
        foreach UpdateResult update in updates {
            string[] identifierParts = regexp:split(re `\.`, update.identifier);

            string summaryLine = "";
            if identifierParts.length() >= 2 {
                string vendor = identifierParts[0];
                string api = string:'join(".", ...identifierParts.slice(1));
                summaryLine = string `${vendor}/${api}:${update.apiVersion}`;
            } else {
                summaryLine = string `${update.identifier}:${update.apiVersion}`;
            }

            print(string `${update.identifier}: ${update.oldSnapshot} -> ${update.newSnapshot} (${update.updateType} update)`, "Info", 1);
            updateSummary.push(summaryLine);
        }

        // Update repos.json (includes lastChecked for all processed specs)
        error? writeResult = writeReposJson(config);
        if writeResult is error {
            print("Failed to write repos.json: " + writeResult.message(), "Error", 0);
            return writeResult;
        }
        io:println("");
        print("Updated repos.json with new snapshots, content hashes, and lastChecked dates", "Info", 0);

        // Write update summary
        string summaryContent = string:'join("\n", ...updateSummary);
        check io:fileWriteString("../UPDATE_SUMMARY.txt", summaryContent);

        io:println("");
        print("Changes detected and saved. The workflow will create a PR automatically.", "Info", 0);

    } else {
        // Even when no updates are found we still persist the lastChecked
        // updates so that the frequency gate advances correctly next run.
        error? writeResult = writeReposJson(config);
        if writeResult is error {
            print("Failed to write repos.json: " + writeResult.message(), "Error", 0);
            return writeResult;
        }
        print("All specifications are up-to-date! Updated lastChecked dates in repos.json.", "Info", 0);
    }
}
