param([int]$Port,[string]$Mode='cpu',[string]$Model='lab-mock',[int]$Context=1024)
# Test-only stand-in for llama-server in the CPU-reference lane. It never loads a model.
$ErrorActionPreference='Stop'
$layers=$(if($Mode -ceq 'gpu-layers'){'3'}else{'0'})
if($Mode -cne 'no-offload-line'){[Console]::Error.WriteLine('load_tensors: offloaded '+$layers+'/41 layers to GPU')}
if($Mode -cne 'no-cpu-buffer'){[Console]::Error.WriteLine('load_tensors: CPU_Mapped model buffer size = 1200.00 MiB')}
if($Mode -ceq 'vulkan-model'){[Console]::Error.WriteLine('load_tensors: Vulkan0 model buffer size = 10.00 MiB')}
if($Mode -ceq 'cpu-repack'){[Console]::Error.WriteLine('load_tensors: CPU_REPACK model buffer size = 300.00 MiB')}
if($Mode -ceq 'using-device'){[Console]::Error.WriteLine('llama_prepare_model_devices: using device Vulkan0 (AMD Radeon RX 7900 XTX) (0000:03:00.0) - 20000 MiB free')}
if($Mode -ceq 'vulkan-kv'){[Console]::Error.WriteLine('llama_kv_cache: Vulkan0 KV buffer size = 256.00 MiB')}
elseif($Mode -cne 'no-cpu-kv'){[Console]::Error.WriteLine('llama_kv_cache: CPU KV buffer size = 256.00 MiB')}
if($Mode -ceq 'vulkan-compute'){[Console]::Error.WriteLine('sched_reserve: Vulkan0 compute buffer size = 64.00 MiB')}
elseif($Mode -cne 'no-cpu-compute'){[Console]::Error.WriteLine('sched_reserve: CPU compute buffer size = 64.00 MiB')}
if($Mode -ceq 'vulkan-host'){[Console]::Error.WriteLine('sched_reserve: Vulkan_Host compute buffer size = 4.00 MiB')}
[Console]::Error.WriteLine('llama_context: flash_attn = auto')
[Console]::Error.WriteLine('resolve_fused_ops: Flash Attention enabled')
Start-Sleep -Milliseconds 400
$listener=New-Object Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Start()
function Send($Conn,[string]$Text,[string]$Type='application/json'){
    $bytes=[Text.Encoding]::UTF8.GetBytes($Text)
    $Conn.Response.StatusCode=200;$Conn.Response.ContentType=$Type
    $Conn.Response.ContentLength64=$bytes.Length
    $Conn.Response.OutputStream.Write($bytes,0,$bytes.Length)
    $Conn.Response.Close()
}
while($listener.IsListening){
    $conn=$listener.GetContext()
    $path=$conn.Request.Url.AbsolutePath
    $body=''
    if($conn.Request.HasEntityBody){$reader=New-Object IO.StreamReader($conn.Request.InputStream);$body=$reader.ReadToEnd();$reader.Dispose()}
    if($path -ceq '/health'){Send $conn '{"status":"ok"}'}
    elseif($path -ceq '/v1/models'){Send $conn ('{"data":[{"id":"'+$Model+'"}]}')}
    elseif($path -ceq '/props'){Send $conn ('{"default_generation_settings":{"n_ctx":'+$Context+'},"total_slots":1}')}
    elseif($path -ceq '/completion'){Send $conn '{"tokens":[123]}'}
    elseif($path -ceq '/v1/chat/completions'){
        if($body -match '"stream"\s*:\s*true'){
            Send $conn ("data: {`"choices`":[{`"delta`":{`"content`":`"Hi`"}}]}`n`ndata: [DONE]`n`n") 'text/event-stream'
        }else{Send $conn '{"choices":[{"message":{"role":"assistant","content":"Hello"},"finish_reason":"stop"}]}'}
    }else{$conn.Response.StatusCode=404;$conn.Response.Close()}
}
