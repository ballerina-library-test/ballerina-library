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

    string command;

    if operationCount <= MAX_OPERATIONS {
        if !quietMode {
            io:println(string `Using all ${operationCount} operations`);
        }
        command = string `bal openapi -i ${specPath} -o ${mockServerDir}`;
    } else {
        if !quietMode {
            io:println(string `Filtering from ${operationCount} to ${MAX_OPERATIONS} most useful operations`);
        }
        string operationsList = check selectOperationsUsingAI(specPath, quietMode);
        if !quietMode {
            io:println(string `Selected operations: ${operationsList}`);
        }
        command = string `bal openapi -i ${specPath} -o ${mockServerDir} --operations ${operationsList}`;
    }

    // generate mock service template using openapi tool
    utils:CommandResult result = utils:executeCommand(command, ballerinaDir, quietMode);
    if !result.success {
        return error("Failed to generate mock server using ballerina openAPI tool: " + result.stderr);
    }

    // The bal openapi command creates different file names depending on the input
    // Common patterns: service.bal, <spec_name>_service.bal, aligned_ballerina_openapi_service.bal
    // We need to find the generated service file and rename it to mock_server.bal

    string mockServerPathNew = mockServerDir + "/mock_server.bal";

    // Try different possible file names that bal openapi might create
    string[] possibleFileNames = [
        "service.bal",
        "aligned_ballerina_openapi_service.bal",
        "openapi_service.bal"
    ];

    boolean fileRenamed = false;

    // First, try to find any *_service.bal file in the directory
    file:MetaData[] files = check file:readDir(mockServerDir);

    foreach file:MetaData fileMetadata in files {
        string fileName = fileMetadata.absPath;
        // Extract just the filename from the full path
        string[] pathParts = regexp:split(re `/`, fileName);
        string actualFileName = pathParts[pathParts.length() - 1];

        // Check if it's a service file (ends with _service.bal or is service.bal)
        if (actualFileName.endsWith("_service.bal") || actualFileName == "service.bal") &&
           actualFileName != "mock_server.bal" {
            // Found the service file, rename it
            if !quietMode {
                io:println(string `Found generated service file: ${actualFileName}`);
            }
            check file:rename(fileName, mockServerPathNew);
            if !quietMode {
                io:println("Renamed to mock_server.bal");
            }
            fileRenamed = true;
            break;
        }
    }

    // If we didn't find a service file, something went wrong
    if !fileRenamed {
        // List all files in the directory for debugging
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

function countOperationsInSpec(string specPath) returns int|error {
    string specContent = check io:fileReadString(specPath);

    // count operationId occurences in the spec
    regexp:RegExp operationIdPattern = re `"operationId"\s*:\s*"[^"]*"`;
    regexp:Span[] matches = operationIdPattern.findAll(specContent);
    return matches.length();

}
