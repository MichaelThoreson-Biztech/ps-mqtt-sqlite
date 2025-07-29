# Ensure the modules are installed and import it
if (-not (Get-Module -ListAvailable -Name PSSQLite)) {
    Install-Module -Name PSSQLite -Scope CurrentUser -Force
}
if (-not (Get-Module -ListAvailable -Name PSMQTT)) {
    Install-Module -Name PSMQTT -Scope CurrentUser -Force
}
Import-Module PSSQLite
Import-Module PSMQTT

# Function to handle incoming MQTT messages
# function OnMessageReceived {
#    param (
#        [string]$topic,
#        [string]$message,
#        [string]$dbPath
#    )
#    Write-host "called OnMessageReceived"
#
#    # Insert data into SQLite database
#    $insertQuery = "INSERT INTO SensorData (Topic, Message) VALUES ('$topic', '$message');"
#    try {
#        Invoke-SqliteQuery -DataSource $dbPath -Query $insertQuery
#    } catch {
#        Write-Host "Failed to insert data into database: $_" -ForegroundColor Red
#    }
#}

# Function to connect to MQTT broker and subscribe to a single topic
# function Connect-MQTTBrokerAndSubscribe {
#     param (
#         [string]$broker,
#         [string]$topic,
#         [string]$dbPath
#     )
# 
#     Write-host "called Connect-MQTTBrokerAndSubscribe"
#     $session = Connect-MQTTBroker -HostName $broker
#     Watch-MQTTTopic -Session $session -Topic $topic | ForEach-Object {
#         $messageParts = $_ -split ";"
#         $receivedTopic = $messageParts[0]
#         $receivedMessage = $messageParts[1]
#         OnMessageReceived -topic $receivedTopic -message $receivedMessage -dbPath $dbPath
#     }
# }

# function to create a query for a new job

$queries = [System.Collections.ArrayList]@(
    @(
@"
        CREATE TABLE IF NOT EXISTS Machines (
            Id INTEGER PRIMARY KEY AUTOINCREMENT,
            Name TEXT NOT NULL
        );
"@ 
    );
    @(
@"
        INSERT INTO Machines (name) 
        VALUES ('debarker');
"@ 
    );
    @(
@"
        CREATE TABLE IF NOT EXISTS log_count (
            Id INTEGER PRIMARY KEY AUTOINCREMENT,
            Machine_ID DEFAULT 1,
            Timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
            Seq INTEGER
        );
"@ 
    );
)

#function to get the value after the first occurance of a specified Key in a JSON message
function Get-Attribute {
    param (
        [Parameter(Mandatory=$true)] [string] $Key,
        [Parameter(Mandatory=$true, ValueFromPipeline)] [string] $Target
    )
 if ($Target -match "^.*{.*\`"seq\\?\`"\:\`"?(\w+)[\\}`"]") {
         $matches[1]  
     } else {
        Write-Error "No match!"
    }
}
function Initialize-Database {
    param (
        [string]$dbPath,
        [System.collections.ArrayList]$dbQueries
    )
    Write-host "called Initialize-Database"
    $dbPath | Write-Host
    Test-Path $dbPath | Write-Host

    if (-Not (Test-Path $dbPath)) {
        Write-Host "try conditional"
        try {
            foreach ($query in $dbQueries){
                Write-Host "Query - `n $query"
                Invoke-SqliteQuery -DataSource $dbPath -Query $query
            }
        }
        catch {
            Write-Host "Failed to create database and table: $_" -ForegroundColor Red
        }
    }
    else {
        Write-Host "no try condition"
    }
}

# Function to start a job for a topic
function Start-TopicJob {
    param (
        [string]$broker,
        [string]$topic,
        [string]$dbPath
    )

    Start-Job -ScriptBlock {
        param ($broker, $topic, $dbPath)

        ${function:Get-Attribute} = "${using:function:Get-Attribute}"
        function OnMessageReceived {
            param (
                [string]$topic,
                [string]$message,
                [string]$dbPath
            )
            Write-Host "$topic, $message"
            $dataVal = $message | Get-Attribute -Key 'seq'

            $insertQuery = "INSERT INTO log_count (seq) VALUES ('$dataVal');"
            try {
                Invoke-SqliteQuery -DataSource $dbPath -Query $insertQuery
            }
            catch {
                Write-Host "Failed to insert data into database: $_" -ForegroundColor Red
            }
        }

        function Connect-MQTTBrokerAndSubscribe {
            param (
                [string]$broker,
                [string]$topic,
                [string]$dbPath
            )

            $session = Connect-MQTTBroker -HostName $broker
            Watch-MQTTTopic -Session $session -Topic $topic | ForEach-Object {
                $messageParts = $_ -split ";"
                $receivedTopic = $messageParts[0]
                $receivedMessage = $messageParts[1]
                OnMessageReceived -topic $receivedTopic -message $receivedMessage -dbPath $dbPath
            }
        }
        Import-Module PSMQTT
        Import-Module PSSQLite
        try {
            Write-Host "calling Connect-MQTTBrokerAndSubscribe"
            Connect-MQTTBrokerAndSubscribe -broker $broker -topic $topic -dbPath $dbPath
            Write-Host "Finished calling Connect-MQTTBrokerAndSubscribe"
        }
        catch {
            Write-Host "Error in job for topic ${topic}: $_" -ForegroundColor Red
        }
    } -ArgumentList $broker, $topic, $dbPath
}

# Function to clean up jobs
function Cleanup-Jobs {
    param (
        [array]$jobs
    )
    Write-Host "called Cleanup-Jobs"

    foreach ($job in $jobs) {
        if ($job.State -ne 'Completed') {
            Stop-Job -Job $job
        }
        Remove-Job -Job $job
    }
}

# Main script
#on-site:
$mqttBroker = "192.168.203.127"
#local (testing): 
#$mqttBroker = "192.168.203.223"

$topics = @("decoded/debarker/log_count")
$dbDirectory = [System.Environment]::GetEnvironmentVariable('SQLITEPATH')
if (-not $dbDirectory) {
    $dbDirectory = "C:\Windows\Temp\mqtt"
    if (-not (Test-Path $dbDirectory)) {
        New-Item -Path $dbDirectory -ItemType Directory | Out-Null
    }
}
$dbPath = Join-Path -Path $dbDirectory -ChildPath "db_organized.sqlite3"

# Initialize database
Initialize-Database -dbPath $dbPath -dbQueries $queries

# Start jobs for each topic
$jobs = @()
foreach ($topic in $topics) {
    $jobs += Start-TopicJob -broker $mqttBroker -topic $topic -dbPath $dbPath
}

# Monitor jobs and handle script termination
try {
    while ($true) {
        foreach ($job in $jobs) {
                $job | Receive-Job  # See if job output is available (non-blocking) and pass it through
                Start-Sleep 1       # Do other things or sleep a little.
            if ($job.State -eq 'Completed') {
                try {
                    Receive-Job -Job $job
                }
                catch {
                    Write-Host "Error in job for topic $($job.ChildJobs[0].Command): $_" -ForegroundColor Red
                }
                finally {
                    Remove-Job -Job $job
                    $jobs = $jobs | Where-Object { $_ -ne $job }
                }
            }
        }
        Start-Sleep -Seconds 1
    }
}


finally {
    Cleanup-Jobs -jobs $jobs
}