function response = olympus_exchange_json(port,request,timeoutMs)
% One bounded local JSON-line transaction, including cleanup on errors.
if nargin<3, timeoutMs=190000; end
socket=javaObject('java.net.Socket');
cleanup=onCleanup(@()socket.close());
socket.connect(javaObject('java.net.InetSocketAddress','127.0.0.1',port),3000);
socket.setSoTimeout(timeoutMs);
reader=javaObject('java.io.BufferedReader',javaObject('java.io.InputStreamReader',socket.getInputStream(),'UTF-8'));
writer=javaObject('java.io.PrintWriter',javaObject('java.io.OutputStreamWriter',socket.getOutputStream(),'UTF-8'),true);
writer.println(jsonencode(request));
line=reader.readLine();
if isempty(line), error('Olympus:NoResponse','Port %d returned no JSON response.',port); end
response=jsondecode(char(line));
end
