$computerName = $env:computername
$user = "ONTAPUser"
$securestring = Get-Content -Path "C:\Users\User1\Documents\ONTAPUser.txt" | ConvertTo-SecureString
$credential = new-object management.automation.pscredential $user, $securestring

$outfile = "$env:TMP\FlexCloneAnalysis.csv"
$outfileappend = "$env:TMP\FlexCloneAnalysis_FlexGroupConstituentsAppend.csv"

#$clusters = Get-Content "C:\Users\User1\Documents\ClusterList.txt"
$clusters = @("cluster1", "cluster2")
$out_arr = @("cluster,vserver,flexclone,create-time,parent-volume,parent-snapshot,state,aggregate,volume-style-extended,size,used,split-estimate,flexclone-used-percent,size(Raw),used(Raw),TotalOps,ReadOps,WriteOps,OtherOps,Read(Bps),Write(Bps),Latency(us),Age(Days),NFSClientsMounted")
$out_arrConst = @("cluster,volume,vserver,aggregate,TotalOps,ReadOps,WriteOps,OtherOps,Read(Bps),Write(Bps),Latency(us)")

Function send_email($code){
    switch($code){
    1{$attach = $outfile}
    2{$attach = $outfileappend}
    3{$attach = @($outfile, $outfileappend)}
    }
	$emailFrom = "no-reply@companydomain.com"
	$emailTo = "user.lastname@companydomain.com"
	$smtpServer = "smtp-server.companydomain.com"
    $subject = "FlexClone performance report"
    $body = "AUTOMATION: Please find attached FlexClone performance report.`n `n `t  Script ran from $computerName `n `n"

	Send-MailMessage `
	      -From $emailFrom `
	      -To $emailTo `
	      -Subject $subject `
	      -Body $body `
	      -Attachment $attach `
	      -SmtpServer $smtpserver
}

Function fileCleanup($file_out){
    if (test-path $file_out) {del $file_out}
}

Function addTimeFrames($file, $out_array, $sd){
    $enddate = Get-Date
    $enddate_str = "End performance data collection: "+$enddate
    "Start performance data collection: "+$sd.ToString() > $file
    Add-Content -Value $enddate_str -Path $file
    Add-Content -Value $out_array -Path $file
}

$startdate = Get-Date
foreach ($cluster in $clusters){
    Connect-NcController $cluster -Credential $credential
    $clones = Get-NcVolClone
    $commFields = "size,used,split-estimate,flexclone-used-percent"
    foreach($clone in $clones){
        $volInfo = Get-NcVol -Name $clone.Name
        $volStyle = ($volInfo).VolumeIdAttributes.StyleExtended
        $volCreate = ($volInfo).VolumeIdAttributes.CreationTimeDT
        $clone.Vserver+","+$clone.Volume
        $perf_cli = (Invoke-NcSSH statistics volume show -vserver $clone.Vserver -volume $clone.Volume -interval 5)
        $perf = ($perf_cli.ToString() -replace("^(?:.*\n?){8}", "") -replace("\s+",",")).TrimEnd(",") -replace ("^([^,]*,[^,]*,[^,]*,)","")
        $clone_cli = (Invoke-NcSSH volume clone show -vserver $clone.Vserver -flexclone $clone.Volume -fields $commFields)
        $clone_info = ($clone_cli.ToString() -replace("^(?:.*\n?){4}", "") -replace("\s+",",")).TrimEnd(",") -replace ("^([^,]*,[^,]*,)","")
        $age = $startdate - $volCreate
        $clients = Get-NcNfsConnectedClient -Volume $volInfo | Select-Object ClientIp | Format-Table -hidetableheader
        if ($clients -eq $null){
            $clientsMounted = "none"
        }
        else{
            $clientsMounted = (($clients | Out-String) -replace("\r\n",";")).TrimStart(";").TrimEnd(";;;")
        }
        if ($clone.State -eq "online"){
            $usedRaw = $volInfo.VolumeSpaceAttributes.SizeUsed
            $out_arr += $cluster+","+$clone.Vserver+","+$clone.Name+","+$volCreate+","+$clone.ParentVolume+","+$clone.ParentSnapshot+","+$clone.State+","+$clone.Aggregate+","+$volStyle+","+$clone_info+","+$clone.Size+","+$usedRaw+","+$perf+","+$age.Days+","+$clientsMounted
        }
        else{
            $usedRaw = "-,"
            $out_arr += $cluster+","+$clone.Vserver+","+$clone.Name+","+$volCreate+","+$clone.ParentVolume+","+$clone.ParentSnapshot+","+$clone.State+","+$clone.Aggregate+","+$volStyle+","+$clone_info+","+$clone.Size+","+$usedRaw+"-,-,-,-,-,-,-"+","+$age.Days+","+$clientsMounted
        }
        if ($volStyle -eq "flexgroup"){
            $constituents = (Get-NcVol -Name $clone.Name).Constituents.Name
            foreach ($constituent in $constituents){
                $constituent
                $const_perf_cli = (Invoke-NcSSH statistics volume show -vserver $clone.Vserver -volume $constituent -interval 5)
                $const_perf = ($const_perf_cli.ToString() -replace("^(?:.*\n?){8}", "") -replace("\s+",",")).TrimEnd(",") 
                $out_arrConst += $cluster+","+$const_perf
            }
        }
#break ##
    }
}

### Selecting the message code & writing out the arrays to a file
if (($out_arr.count -ne 1) -or ($out_arrConst.count -ne 1)){
    if (($out_arr.count -ne 1) -and ($out_arrConst.count -eq 1)){
        fileCleanup ($outfile)
        addTimeFrames $outfile $out_arr $startdate
        $msgCode = 1
    }
    if (($out_arr.count -eq 1) -and ($out_arrConst.count -ne 1)){
        fileCleanup ($outfileappend)
        addTimeFrames $outfileappend $out_arrConst $startdate
        $msgCode = 2
    }
    if (($out_arr.count -ne 1) -and ($out_arrConst.count -ne 1)){
        fileCleanup ($outfile)
        fileCleanup ($outfileappend)
        addTimeFrames $outfile $out_arr $startdate
        addTimeFrames $outfileappend $out_arrConst $startdate
        $msgCode = 3
    }
    send_email ($msgCode)
} 
