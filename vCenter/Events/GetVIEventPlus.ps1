function Get-VIEventPlus {
    <#
        .SYNOPSIS  Returns vSphere events
        .DESCRIPTION The function will return vSphere events. With
        the available parameters, the execution time can be
        improved, compered to the original Get-VIEvent cmdlet.
        .NOTES  Author:  Luc Dekens
        .PARAMETER Entity
        When specified the function returns events for the
        specific vSphere entity. By default events for all
        vSphere entities are returned.
        .PARAMETER EventType
        This parameter limits the returned events to those
        specified on this parameter.
        .PARAMETER Start
        The start date of the events to retrieve
        .PARAMETER Finish
        The end date of the events to retrieve.
        .PARAMETER Recurse
        A switch indicating if the events for the children of
        the Entity will also be returned
        .PARAMETER User
        The list of usernames for which events will be returned
        .PARAMETER System
        A switch that allows the selection of all system events.
        .PARAMETER ScheduledTask
        The name of a scheduled task for which the events
        will be returned
        .PARAMETER FullMessage
        A switch indicating if the full message shall be compiled.
        This switch can improve the execution speed if the full
        message is not needed.
        .EXAMPLE
        PS> Get-VIEventPlus -Entity $vm
        .EXAMPLE
        PS> Get-VIEventPlus -Entity $cluster -Recurse:$true
    #>
    param(
        [object[]]$Entity,
        [string[]]$EventType,
        [DateTime]$Start,
        [DateTime]$Finish = (Get-Date),
        [switch]$Recurse,
        [string[]]$User,
        [Switch]$System,
        [string]$ScheduledTask,
        [switch]$FullMessage = $false,
        $Server
    )
    process {
        $eventnumber = 100
        $ErrorActionPreference = 'Stop'
        if (-not $Server) {
            $defaults = Get-Variable -Name DefaultVIServers -Scope Global -ValueOnly -ErrorAction SilentlyContinue
            if (!$defaults) { $defaults = Get-Variable -Name DefaultVIServer -Scope Global -ValueOnly -ErrorAction SilentlyContinue }
            $connections = @($defaults | Where-Object { $_ -and $_.IsConnected })
            if ($connections.Count -ne 1) { throw 'Specify -Server when there is not exactly one default vCenter connection.' }
            $Server = $connections[0]
        }
        if ([WildcardPattern]::ContainsWildcardCharacters([string]$Server)) { throw 'Specify one exact vCenter server.' }

        $instance = Get-View ServiceInstance -Server $Server
        $eventMgr = Get-View EventManager -Server $Server
        $eventFilter = New-Object VMware.Vim.EventFilterSpec
        $eventFilter.disableFullMessage = ! $FullMessage
        $eventFilter.eventTypeId = $EventType
        if ($Start -or $Finish) {
            $eventFilter.time = New-Object VMware.Vim.EventFilterSpecByTime
            if ($Start) {
                $eventFilter.time.beginTime = $Start
            }
            if ($Finish) {
                $eventFilter.time.endTime = $Finish
            }
        }
        if ($User -or $System) {
            $eventFilter.UserName = New-Object VMware.Vim.EventFilterSpecByUsername
            if ($User) {
                $eventFilter.UserName.userList = $User
            }
            if ($System) {
                $eventFilter.UserName.systemUser = $System
            }
        }
        if ($ScheduledTask) {
            $manager = Get-View -Id $instance.Content.ScheduledTaskManager -Server $Server
            $tasks = @(foreach ($ref in $manager.ScheduledTask) {
                    Get-View -Id $ref -Server $Server | Where-Object { $_.Info.Name -ceq $ScheduledTask }
                })
            if ($tasks.Count -ne 1) { throw 'Expected one matching scheduled task.' }
            $eventFilter.ScheduledTask = $tasks[0].MoRef
        }
        $seen = [System.Collections.Generic.HashSet[int]]::new()
        $targets = @($Entity)
        if (!$Entity) { $targets = , $null }
        foreach ($item in $targets) {
            if ($item) {
                if ($item.ExtensionData.Client.ServiceContent.About.InstanceUuid -ne $instance.Content.About.InstanceUuid) { throw 'Entity belongs to a different vCenter.' }
                $eventFilter.Entity = [VMware.Vim.EventFilterSpecByEntity]::new()
                $eventFilter.Entity.Entity = $item.ExtensionData.MoRef
                $eventFilter.Entity.Recursion = if ($Recurse) { 'all' } else { 'self' }
            }
            $ref = $eventMgr.CreateCollectorForEvents($eventFilter)
            $collector = Get-View -Id $ref -Server $Server
            try {
                do {
                    $batch = $collector.ReadNextEvents($eventnumber)
                    foreach ($entry in $batch) { if ($seen.Add($entry.Key)) { $entry } }
                } while ($batch)
            }
            finally { $collector.DestroyCollector() }
        }
    }
}
function Get-MotionHistory {
    <#
        .SYNOPSIS  Returns the vMotion/svMotion history
        .DESCRIPTION The function will return information on all
        the vMotions and svMotions that occurred over a specific
        interval for a defined number of virtual machines
        .NOTES  Author:  Luc Dekens
        .PARAMETER Entity
        The vSphere entity. This can be one more virtual machines,
        or it can be a vSphere container. If the parameter is a
        container, the function will return the history for all the
        virtual machines in that container.
        .PARAMETER Days
        An integer that indicates over how many days in the past
        the function should report on.
        .PARAMETER Hours
        An integer that indicates over how many hours in the past
        the function should report on.
        .PARAMETER Minutes
        An integer that indicates over how many minutes in the past
        the function should report on.
        .PARAMETER Sort
        An switch that indicates if the results should be returned
        in chronological order.
        .EXAMPLE
        PS> Get-MotionHistory -Entity $vm -Days 1
        .EXAMPLE
        PS> Get-MotionHistory -Entity $cluster -Sort:$false
        .EXAMPLE
        PS> Get-Datacenter -Name $dcName |
        >> Get-MotionHistory -Days 7 -Sort:$false
    #>
    [CmdletBinding(DefaultParameterSetName = "Days")]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [object[]]$Entity,
        [Parameter(ParameterSetName = 'Days')]
        [int]$Days = 1,
        [Parameter(ParameterSetName = 'Hours')]
        [int]$Hours,
        [Parameter(ParameterSetName = 'Minutes')]
        [int]$Minutes,
        [switch]$Recurse = $false,
        [switch]$Sort,
        $Server
    )
    begin {
        $history = @()
        switch ($psCmdlet.ParameterSetName) {
            'Days' {
                $start = (Get-Date).AddDays(- $Days)
            }
            'Hours' {
                $start = (Get-Date).AddHours(- $Hours)
            }
            'Minutes' {
                $start = (Get-Date).AddMinutes(- $Minutes)
            }
        }
        $eventTypes = "DrsVmMigratedEvent", "VmMigratedEvent"
    }
    process {
        $history += Get-VIEventPlus -Entity $entity -Server $Server -Start $start -EventType $eventTypes -Recurse:$Recurse | Select-Object CreatedTime, @{N = "Type"; E = { if ($_.SourceDatastore.Name -eq $_.Ds.Name) { "vMotion" }else { "svMotion" } } },
        @{N = "UserName"; E = { if ($_.UserName) { $_.UserName }else { "System" } } },
        @{N = "VM"; E = { $_.VM.Name } },
        @{N = "SrcVMHost"; E = { $_.SourceHost.Name.Split('.')[0] } },
        @{N = "TgtVMHost"; E = { if ($_.Host.Name -ne $_.SourceHost.Name) { $_.Host.Name.Split('.')[0] } } },
        @{N = "SrcDatastore"; E = { $_.SourceDatastore.Name } },
        @{N = "TgtDatastore"; E = { if ($_.Ds.Name -ne $_.SourceDatastore.Name) { $_.Ds.Name } } }
    }
    end {
        if (!$PSBoundParameters.ContainsKey('Sort') -or $Sort) {
            $history | Sort-Object -Property CreatedTime
        }
        else {
            $history
        }
    }
}
