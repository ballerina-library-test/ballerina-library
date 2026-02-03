import connector_automator.utils;

import ballerina/file;
import ballerina/io;
import ballerina/lang.regexp;

function setupMockServerModule(string connectorPath, boolean quietMode = false) returns error? {
    string ballerinaDir = connectorPath + "/ballerina";
    // cd into ballerina dir and add mock.server module using bal add cmd

    if !quietMode {
        io:println("Setting up mock.server module...");
    }

    string command = string `bal add mock.server`;

    utils:CommandResult addResult = utils:executeCommand(command, ballerinaDir, quietMode);
    if !addResult.success {
        return error("Failed to add mock.server module" + addResult.stderr);
    }

    if !quietMode {
        io:println("✓ Mock.server module added successfully");
    }

    // delete the auto generated tests directory
    string mockTestDir = ballerinaDir + "/modules/mock.server/tests";
    if check file:test(mockTestDir, file:EXISTS) {
        check file:remove(mockTestDir, file:RECURSIVE);
        if !quietMode {
            io:println("Removed auto generated tests directory");
        }
    }

    // delete auto generated mock.server.bal file (if it exists)
    string mockServerFile = ballerinaDir + "/modules/mock.server/mock.server.bal";
    if check file:test(mockServerFile, file:EXISTS) {
        check file:remove(mockServerFile, file:RECURSIVE);
        if !quietMode {
            io:println("Removed auto generated mock.server.bal file");
        }
    }

    return;
}

function generateMockServer(string connectorPath, string specPath, boolean quietMode = false) returns error? {
    string ballerinaDir = connectorPath + "/ballerina";
    string mockServerDir = ballerinaDir + "/modules/mock.server";
    int operationCount = check countOperationsInSpec(specPath);
    if !quietMode {
        io:println(string `Total operations found in spec: ${operationCount}`);
    }

    // CRITICAL FIX: bal openapi with --operations flag does NOT generate service files
    // We must ALWAYS generate without --operations first, then filter the service file later

    string command = string `bal openapi -i ${specPath} -o ${mockServerDir}`;

    // Track selected operations for later filtering
    string[]? selectedOperationIds = ();

    if operationCount > MAX_OPERATIONS {
        if !quietMode {
            io:println(string `Will filter from ${operationCount} to ${MAX_OPERATIONS} most useful operations after generation`);
        }
        string operationsList = check selectOperationsUsingAI(specPath, quietMode);
        selectedOperationIds = regexp:split(re `,`, operationsList);
        if !quietMode {
            io:println(string `Selected operations: ${operationsList}`);
        }
    } else {
        if !quietMode {
            io:println(string `Using all ${operationCount} operations`);
        }
    }

    // Generate mock service WITHOUT --operations flag (this is the key fix)
    utils:CommandResult result = utils:executeCommand(command, ballerinaDir, quietMode);
    if !result.success {
        return error("Failed to generate mock server using ballerina openAPI tool: " + result.stderr);
    }

    // Find and rename the generated service file
    string mockServerPathNew = mockServerDir + "/mock_server.bal";

    // Scan directory for the service file
    file:MetaData[] files = check file:readDir(mockServerDir);

    boolean fileRenamed = false;
    string serviceFilePath = "";

    foreach file:MetaData fileMetadata in files {
        string fileName = fileMetadata.absPath;
        string[] pathParts = regexp:split(re `/`, fileName);
        string actualFileName = pathParts[pathParts.length() - 1];

        // Check if it's a service file
        if (actualFileName.endsWith("_service.bal") || actualFileName == "service.bal") &&
           actualFileName != "mock_server.bal" {
            serviceFilePath = fileName;
            if !quietMode {
                io:println(string `Found generated service file: ${actualFileName}`);
            }

            // If we need to filter operations, do it now BEFORE renaming
            if selectedOperationIds is string[] {
                if !quietMode {
                    io:println(string `Filtering service to ${selectedOperationIds.length()} operations...`);
                }
                check filterServiceOperations(serviceFilePath, selectedOperationIds);
                if !quietMode {
                    io:println("✓ Service filtered to selected operations");
                }
            }

            // Now rename to mock_server.bal
            check file:rename(fileName, mockServerPathNew);
            if !quietMode {
                io:println("Renamed to mock_server.bal");
            }
            fileRenamed = true;
            break;
        }
    }

    if !fileRenamed {
        io:println("✗ Could not find generated service file in mock.server directory");
        if !quietMode {
            io:println("Files in mock.server directory:");
            foreach file:MetaData fileMetadata in files {
                string[] pathParts = regexp:split(re `/`, fileMetadata.absPath);
                io:println(string `  - ${pathParts[pathParts.length() - 1]}`);
            }
        }
        return error("bal openapi did not generate a service file");
    }

    // delete client.bal if it exists
    string clientPath = mockServerDir + "/client.bal";
    if check file:test(clientPath, file:EXISTS) {
        check file:remove(clientPath, file:RECURSIVE);
        if !quietMode {
            io:println("Removed client.bal");
        }
    }

    return;
}

// NEW FUNCTION: Filter service file to only include selected operations
function filterServiceOperations(string serviceFilePath, string[] selectedOps) returns error? {
    string serviceContent = check io:fileReadString(serviceFilePath);

    // Split into lines
    string[] lines = regexp:split(re `\n`, serviceContent);
    string[] filteredLines = [];

    boolean inResourceFunction = false;
    boolean keepCurrentFunction = false;
    string[] currentFunction = [];
    int braceDepth = 0;

    foreach string line in lines {
        // Check if this is a resource function declaration
        if line.includes("resource function") {
            inResourceFunction = true;
            currentFunction = [];
            braceDepth = 0;

            // Check if this operation should be kept
            keepCurrentFunction = false;
            foreach string op in selectedOps {
                // Match operation ID in the function signature
                // Example: "resource function get Accounts/..." might match "ListAccount"
                if line.includes(op) {
                    keepCurrentFunction = true;
                    break;
                }
            }
        }

        if inResourceFunction {
            currentFunction.push(line);

            // Count braces to find end of function
            if line.includes("{") {
                braceDepth += countOccurrences(line, "{");
            }
            if line.includes("}") {
                braceDepth -= countOccurrences(line, "}");
            }

            // End of function
            if braceDepth == 0 && currentFunction.length() > 1 {
                if keepCurrentFunction {
                    // Add this function to output
                    foreach string funcLine in currentFunction {
                        filteredLines.push(funcLine);
                    }
                }
                inResourceFunction = false;
                currentFunction = [];
            }
        } else {
            // Not in a resource function - keep the line (headers, imports, etc.)
            filteredLines.push(line);
        }
    }

    // Write filtered content back
    string filteredContent = string:'join("\n", ...filteredLines);
    check io:fileWriteString(serviceFilePath, filteredContent);

    return;
}

function countOccurrences(string text, string char) returns int {
    int count = 0;
    int currentPos = 0;

    while true {
        int? pos = text.indexOf(char, currentPos);
        if pos is () {
            break;
        }
        count += 1;
        currentPos = pos + 1;
    }

    return count;
}

function countOperationsInSpec(string specPath) returns int|error {
    string specContent = check io:fileReadString(specPath);

    // count operationId occurences in the spec
    regexp:RegExp operationIdPattern = re `"operationId"\s*:\s*"[^"]*"`;
    regexp:Span[] matches = operationIdPattern.findAll(specContent);
    return matches.length();

}
