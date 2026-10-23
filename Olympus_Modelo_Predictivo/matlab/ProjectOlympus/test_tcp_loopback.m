function test_tcp_loopback(port)
% Run this server for one message; use test_olympus_tcp_client.py externally.
if nargin<1, port=55002; end
start_olympus_tcp_server(port,1,'rom');
end
