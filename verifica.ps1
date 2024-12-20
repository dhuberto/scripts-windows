# Condições para enviar o e-mail
$diskThresholdGB = 150  # Espaço livre mínimo em GB para disparar alerta
$memoryThresholdPercent = 60  # Percentual de uso de memória para disparar alerta
$cpuThresholdPercent = 60  # Percentual de uso de CPU para disparar alerta

# Tolerâncias
$diskToleranceGB = 1  # Tolerância de 1 GB para mudanças no disco
$memoryTolerancePercent = 5  # Tolerância de 5% para mudanças na memória
$cpuTolerancePercent = 5  # Tolerância de 5% para mudanças na CPU

# Obter o hostname
$hostname = $env:COMPUTERNAME

# Obter o IP (IPv4) que começa com '192.168.0.'
$ip = (Get-NetIPConfiguration | Where-Object { $_.IPv4Address.IPAddress -like '192.168.0.*' -and $_.NetAdapter.Status -eq 'Up' }).IPv4Address.IPAddress

# Configurações do e-mail
$smtpServer = "smtps.teste.com.br"
$smtpPort = 587
$smtpFrom = "alerta@teste.com.br"
$smtpTo = "lista-infra@teste.com.br"
$subject = "Alerta: Servidor $hostname IP: $ip - Recursos do Sistema Críticos"
$credential = New-Object System.Management.Automation.PSCredential ("alerta", (ConvertTo-SecureString "alertassenha" -AsPlainText -Force))

# Caminho do arquivo de estado anterior
$logFilePath = "C:\script\estado_sistema.txt"

# Função para obter estado anterior
function Obter-EstadoAnterior {
    if (Test-Path $logFilePath) {
        try {
            return Import-Clixml $logFilePath
        } catch {
            Write-Output "Erro ao importar estado anterior: $($_.Exception.Message)"
            Remove-Item $logFilePath
            Write-Output "Arquivo de estado anterior corrompido. Será recriado."
            return $null
        }
    }
    return $null
}

# Função para armazenar estado atual
function Armazenar-EstadoAtual {
    param (
        [hashtable]$estado
    )
    try {
        $estado | Export-Clixml $logFilePath
        Write-Output "Estado atual armazenado com sucesso."
    } catch {
        Write-Output "Erro ao armazenar o estado atual: $_"
    }
}

# Função para checar o estado atual do sistema
function Checar-EstadoSistema {
    $drives = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Used -ne 0 }
    $discoCritico = @()
    $estadoDiscos = @()
    
    foreach ($drive in $drives) {
        $espacoLivreGB = [math]::Round($drive.Free / 1GB, 2)
        $tamanhoTotalGB = [math]::Round(($drive.Used + $drive.Free) / 1GB, 2)
        $estadoDiscos += "Drive $($drive.Name): Espaço Livre = $espacoLivreGB GB, Espaço Total = $tamanhoTotalGB GB"

        if ($espacoLivreGB -lt $diskThresholdGB) {
            $discoCritico += @{
                Nome = $drive.Name
                EspacoLivre = $espacoLivreGB
                TamanhoTotal = $tamanhoTotalGB
            }
        }
    }

    $memoriaTotalGB = [math]::Round((Get-CimInstance -ClassName Win32_OperatingSystem).TotalVisibleMemorySize / 1MB, 2)
    $memoriaLivreGB = [math]::Round((Get-CimInstance -ClassName Win32_OperatingSystem).FreePhysicalMemory / 1MB, 2)
    $memoriaUsadaGB = [math]::Round($memoriaTotalGB - $memoriaLivreGB, 2)
    $usoMemoria = [math]::Round(($memoriaUsadaGB / $memoriaTotalGB) * 100, 2)

    $usoCPU = [math]::Round((Get-Counter '\Processor(_Total)\% Processor Time').CounterSamples.CookedValue, 2)

    return @{
        DiscoCritico = $discoCritico
        EstadoDiscos = $estadoDiscos
        UsoMemoria = $usoMemoria
        UsoCPU = $usoCPU
        MemoriaUsadaGB = $memoriaUsadaGB
        MemoriaTotalGB = $memoriaTotalGB
    }
}

# Função para enviar e-mail de alerta
function Enviar-AlertaEmail {
    param (
        [string]$mensagem
    )
    
    $mailMessage = New-Object system.net.mail.mailmessage
    $mailMessage.from = $smtpFrom
    $mailMessage.To.add($smtpTo)
    $mailMessage.Subject = $subject
    $mailMessage.Body = $mensagem
    
    $smtp = New-Object Net.Mail.SmtpClient($smtpServer, $smtpPort)
    $smtp.Credentials = $credential

    try {
        $smtp.Send($mailMessage)
        Write-Output "E-mail enviado com sucesso."
    } catch {
        Write-Output "Erro ao enviar e-mail: $_"
    }
}

# Verificando estado atual
$estadoAtual = Checar-EstadoSistema

# Verificando estado anterior
$estadoAnterior = Obter-EstadoAnterior

# Verificação de mudanças e tolerâncias
$estadoAlterado = $false
$emailDiscoEnviado = $false
$recursosCriticos = $false
$mensagem = $subject + "`n`n"

if ($estadoAnterior) {
    $emailDiscoEnviado = $estadoAnterior.EmailDiscoEnviado

    foreach ($driveAtual in $estadoAtual.DiscoCritico) {
        $driveAnterior = $estadoAnterior.DiscoCritico | Where-Object { $_.Nome -eq $driveAtual.Nome }

        if ($driveAnterior) {
            $mudancaDisco = [math]::Abs($driveAtual.EspacoLivre - $driveAnterior.EspacoLivre)
            if ($mudancaDisco -ge $diskToleranceGB) {
                $estadoAlterado = $true
            }
        } else {
            $estadoAlterado = $true
        }
    }
} else {
    $estadoAlterado = $true
}

if ($estadoAtual.DiscoCritico.Count -gt 0) {
    $recursosCriticos = $true
    $mensagem += "Espaço livre mínimo definido: $diskThresholdGB GB`n"
    foreach ($drive in $estadoAtual.DiscoCritico) {
        $mensagem += "Drive $($drive.Nome): Espaço Livre = $($drive.EspacoLivre) GB, Espaço Total = $($drive.TamanhoTotal) GB`n"
    }
    $mensagem += "Disco alerta: True`n`n"
} else {
    $mensagem += "Disco alerta: False`n`n"
}

# Exibindo logs no console
Write-Host "`nEspaço livre mínimo definido: $diskThresholdGB GB"
foreach ($disco in $estadoAtual.EstadoDiscos) {
    Write-Host $disco
}
if ($estadoAtual.DiscoCritico.Count -gt 0) {
    Write-Host "Disco alerta: True"
} else {
    Write-Host "Disco alerta: False"
}

# Memória
$mensagem += "`nPercentual de uso de memória máximo definido: $memoryThresholdPercent%`n"
$mensagem += "Uso atual da Memória RAM: $($estadoAtual.MemoriaUsadaGB) GB ($($estadoAtual.UsoMemoria)%)`n"
if ($estadoAtual.UsoMemoria -gt $memoryThresholdPercent) {
    $mensagem += "Memória alerta: True`n`n"
    $recursosCriticos = $true
    $estadoAlterado = $true
} else {
    $mensagem += "Memória alerta: False`n`n"
}

# CPU
$mensagem += "`nPercentual de uso de CPU máximo definido: $cpuThresholdPercent%`n"
$mensagem += "Uso atual da CPU: $($estadoAtual.UsoCPU)%`n"
if ($estadoAtual.UsoCPU -gt $cpuThresholdPercent) {
    $mensagem += "CPU alerta: True`n`n"
    $recursosCriticos = $true
    $estadoAlterado = $true
} else {
    $mensagem += "CPU alerta: False`n`n"
}

# Estado alterado
Write-Host "`nPercentual de uso de memória máximo definido: $memoryThresholdPercent%"
Write-Host "Uso atual da Memória RAM: $($estadoAtual.MemoriaUsadaGB) GB ($($estadoAtual.UsoMemoria)%)"
if ($estadoAtual.UsoMemoria -gt $memoryThresholdPercent) {
    Write-Host "Memória alerta: True"
} else {
    Write-Host "Memória alerta: False"
}

Write-Host "`nPercentual de uso de CPU máximo definido: $cpuThresholdPercent%"
Write-Host "Uso atual da CPU: $($estadoAtual.UsoCPU)%"
if ($estadoAtual.UsoCPU -gt $cpuThresholdPercent) {
    Write-Host "CPU alerta: True"
} else {
    Write-Host "CPU alerta: False"
}

# Enviar e-mail se houver estado alterado e recursos críticos
if ($estadoAlterado -and $recursosCriticos) {
    Enviar-AlertaEmail -mensagem $mensagem
    $emailDiscoEnviado = $true
} else {
    $emailDiscoEnviado = $false
}

# Armazenar estado atual
$estadoAtual.EmailDiscoEnviado = $emailDiscoEnviado
Armazenar-EstadoAtual -estado $estadoAtual
