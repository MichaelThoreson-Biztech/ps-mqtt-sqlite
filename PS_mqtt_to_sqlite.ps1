# Ensure the modules are installed and import it
if (-not (Get-Module -ListAvailable -Name PSSQLite)) {
    Install-Module -Name PSSQLite -Scope CurrentUser -Force
}
if (-not (Get-Module -ListAvailable -Name PSMQTT)) {
    Install-Module -Name PSMQTT -Scope CurrentUser -Force
}
Import-Module PSSQLite
Import-Module PSMQTT

function Initialize-MQTTDB {
    param (
        [string] $DbPath,
        [string] $Sqlscript,
        [boolean] $Overwrite
    )
    $Script = Get-Content -Path "$Sqlscript"
    $Script = $Script -join ''

    if (Test-Path -Path $DbPath) {
        if ($Overwrite) {
            Remove-Item $DbPath
            Invoke-SqliteQuery -DataSource $DbPath -Query $Script 
        }
    } else {
    Invoke-SqliteQuery -DataSource $DbPath -Query $Script 
    }
}

#will be called from New-Message. Recursively populates attributes with reference to parent attr.
function New-Attribute {
    param (
        [parameter(Mandatory = $true)][int64] $Msg_ID,
        [parameter(Mandatory = $true)][System.Data.SQLite.SQLiteConnection] $DbConn,
        [int64] $Attr_Parent,
        [parameter(Mandatory = $true)][PSCustomObject] $Msg_Body,
        [int16] $Depth = 8
    )
    #Write-Host "New-Attribute called with $Msg_ID, Parent: $Attr_Parent, Depth $Depth`n and message:"
    #Write-Host $Msg_Body
    
    #Depth limit to prevent lockups
    if ($Depth -le 0) {
        Throw "Terminated at depth 1"
    }
    else {
        $Depth -= 1
    }
    #insert all non-metadata attributes into attrib table
    $Msg_Body.PSObject.Properties |
    Where-Object { $_.Name -ne 'timestamp' -and $_.Name -ne 'metrics' } |
    ForEach-Object { 
        $currVal = if ($_.Value -is [PSCustomObject]) { 'attr_list' } else { $_.Value }
        $currQuery = if ($Attr_Parent -eq 0) {
            "insert into attrib(msg_ID, key, val) 
        values (@msgID, @key, @value);"
        } else {
            "insert into attrib(msg_ID, parent, key, val) 
        values (@msgID, @parentID, @key, @value);"
        }
        Invoke-SqliteQuery -SQLiteConnection $DbConn -Query $currQuery -SqlParameters @{
            msgID    = $Msg_ID;
            parentID = $Attr_Parent;
            key      = $_.Name;
            value    = $currVal
        }
    }
    #Run for each attrbute with children:
    $Msg_Body.PSObject.Properties | Where-Object { $_.Value -is [PSCustomObject] } |
    ForEach-Object {
        #get ID for parent attribute:   
        $currQuery = "select * from attrib
        WHERE 
         (
            (@curr_parent = 0 AND parent IS NULL)
            OR
            (parent = @curr_parent)
        )
        and msg_ID = @curr_msg
        and key = @curr_key"
        $temp_parent = Invoke-SqliteQuery -SQLiteConnection $DbConn -Query $currQuery -SqlParameters @{
            curr_parent = $Attr_Parent;
            curr_msg    = $Msg_ID;
            curr_key    = $_.Name
        }
        
        #call self, pass on parent's ID
        New-Attribute -DbConn $DbConn -Msg_ID $Msg_ID -Msg_Body $_.Value -Attr_Parent $temp_parent.ID -Depth $Depth
    }
}
#takes: 
#   MQTT topic string in the form "decoded/<Machine>/<Topic"
#   SQLiteConnection
#   MQTT JSON payload with keys "{timestamp, metrics, <tags>}"
#returns: nothing
#side effect: Asserts machine and topic have entry in database, 
#             creates new referential Message entry with associated attributes
#             matching the JSON content of the MQTT message.
function New-Message {
    param (
        [parameter(Mandatory = $true)][string] $Topic,
        [parameter(Mandatory = $true)][System.Data.SQLite.SQLiteConnection] $DbConn,
        [parameter(Mandatory = $true)][string] $Message_JSON,
        [int16] $Depth = 4
    )
    if ($Depth -le 0) {
        throw "Terminated at depth 0"
    }
    else {
        $Depth -= 1
    }
    #Write-host "Invoked New-Message with $Topic, $DbConn, and message:"
    #Write-Host $Message_JSON
       Invoke-SqliteQuery -SQLiteConnection $DbConn -Query "PRAGMA foreign_keys = ON;"
    #parse the mqtt topic string (implementation subject to change)
    $machine = $Topic.split('/')[1]
    $tag = $Topic.split('/')[2]
    #grab the Machine and Tag IDs for later use
    $ids = @{}
    $currQuery = "select Tag.ID Tag
        from Tag
        join Machine on Machine.ID = Tag.Machine_ID
        where Tag.name = @tagname and Machine.name = @machname"
    Invoke-SqliteQuery -SqliteConnection $DbConn -Query $currQuery -SqlParameters @{
        tagname  = $tag;
        machname = $machine
    } | ForEach-Object {
        $ids.Tag = $_.PSObject.Properties.Value
    }
    $currQuery = "select ID Machine
        from machine
        where name = @machname"
    Invoke-SqliteQuery -SqliteConnection $DbConn -Query $currQuery -SqlParameters @{
        machname = $machine
    } | ForEach-Object {
        $ids.Machine = $_.PSObject.Properties.Value
    }
    #TODO Add error handling to both assertions!
    #Assert tag exists
    if (-not $ids.Tag) {
        #Assert machine exists
        if (-not $ids.Machine) {
            #Write-Host "No Machine number found! inserting tag and trying again..."
            $currQuery = "insert into Machine (name) values (@machname)"
            Invoke-SqliteQuery -SqliteConnection $DbConn -Query $currQuery -SqlParameters @{
                machname = $machine
            }
            #Recurse, Now the Machine should exist.
            New-Message -Topic $Topic -DbConn $DbConn -Message_Json $Message_Json -Depth $Depth
        }
        else {
            #Write-Host "No Tag number found! inserting tag and trying again..."
            $currQuery = "insert into Tag (name, machine_ID) values (@tagname, @machid)"
            Invoke-SqliteQuery -SqliteConnection $DbConn -Query $currQuery -SqlParameters @{
                tagname = $tag;
                machid  = $ids.Machine
            }
            #Recurse, now the Tag should exist.
            New-Message -Topic $Topic -DbConn $DbConn -Message_Json $Message_Json -Depth $Depth
        }
    }
    else {
        #DB is in consistent state, now insert the Message
        
        $Message = $Message_JSON | ConvertFrom-Json -Depth 16
        $Message.PSObject.Properties | where-object {$_.Name -eq "timestamp"} | foreach-object {$timestamp = $_.Value}
        $currQuery = "insert into Msg (tag_ID, timestamp) values (@tagID, @msgTime)"
        Invoke-SqliteQuery -SqliteConnection $DbConn -Query $currQuery -SqlParameters @{
            tagID = $ids.Tag;
            msgTime = $timestamp
        }
        #Message has been inserted, grab message's id 
        $currQuery = "select Msg_ID from Machine_Tag_msg
        where Machine_Name = @machName
        and tag_Name = @tagName
        order by Msg_Id desc
        limit 1;"
        $response = Invoke-SqliteQuery -SqliteConnection $DbConn -Query $currQuery -SqlParameters @{
            tagName = $tag;
            machName = $machine; 
        }
        $Msg_ID = $response.Msg_ID
        #insert attribute using message's ID
        New-Attribute -Msg_ID $Msg_ID -Msg_Body $Message -DbConn $DbConn
    }
}
#unused
#function Initialize-Database {
#    param (
#        [string]$dbPath,
#        [System.collections.ArrayList]$dbQueries
#    )
#    Write-host "called Initialize-Database"
#    $dbPath | Write-Host
#    Test-Path $dbPath | Write-Host
#
#    if (-Not (Test-Path $dbPath)) {
#        Write-Host "try conditional"
#        try {
#            foreach ($query in $dbQueries) {
#                Write-Host "Query - `n $query"
#                Invoke-SqliteQuery -DataSource $dbPath -Query $query
#            }
#        }
#        catch {
#            Write-Host "Failed to create database and table: $_" -ForegroundColor Red
#        }
#    }
#}

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
        ${function:New-Message} = "${using:function:New-Message}"
        ${function:New-Attribute} = "${using:function:New-Attribute}"
        function OnMessageReceived {
            param (
                [string]$topic,
                [string]$message,
                [string]$dbPath
            )
            #Write-Host "$topic, $message"
            $dbConn = New-SQLiteConnection -DataSource $dbPath 
            New-Message -Topic $topic -Message_Json $message -DbConn $dbConn
            $dbConn.Close()
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
            #Write-Host "calling Connect-MQTTBrokerAndSubscribe"
            Connect-MQTTBrokerAndSubscribe -broker $broker -topic $topic -dbPath $dbPath
            #Write-Host "Finished calling Connect-MQTTBrokerAndSubscribe"
        }
        catch {
            Write-Error "Error in job for topic ${topic}: $_" -ForegroundColor Red
        }
    } -ArgumentList $broker, $topic, $dbPath
}

# Function to clean up jobs
function Cleanup-Jobs {
    param (
        [array]$jobs
    )
    #Write-Host "called Cleanup-Jobs"

    foreach ($job in $jobs) {
        if ($job.State -ne 'Completed') {
            Stop-Job -Job $job
        }
        Remove-Job -Job $job
    }
}

# Main script
#on-site:
#$mqttBroker = "0.0.0.0"
#local (testing): 
$mqttBroker = "192.168.0.0"

$topics = Get-Content -Path "$PSScriptRoot\topics.txt"
$dbDirectory = [System.Environment]::GetEnvironmentVariable('SQLITEPATH')

if (-not $dbDirectory) {
    $dbDirectory = "C:\Windows\Temp\mqtt"
    if (-not (Test-Path $dbDirectory)) {
        New-Item -Path $dbDirectory -ItemType Directory | Out-Null
    }
}

$dbPath = Join-Path -Path $dbDirectory -ChildPath "db.sqlite3"
# Initialize database
Initialize-MQTTDB -DbPath $dbPath -Sqlscript "$PSScriptRoot\schema.sql"

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
                    #Write-Host "Error in job for topic $($job.ChildJobs[0].Command): $_" -ForegroundColor Red
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
    #Necessary - PSSQlite implementation fails to release file handles on SQLiteConnection.Close():
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
}