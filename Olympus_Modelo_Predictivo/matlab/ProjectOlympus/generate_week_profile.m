function inputs = generate_week_profile(days,dt_s,seed)
%GENERATE_WEEK_PROFILE Create variable multi-day workload and fault inputs.
% Without a seed, every call creates a new stochastic scenario.
if nargin < 1, days = 7; end
if nargin < 2, dt_s = 5; end
if nargin < 3 || isempty(seed), rng('shuffle'); else, rng(seed); end

t = (0:dt_s:days*86400)';
hour = mod(t/3600,24);
dayIndex = floor(t/86400) + 1;
isWeekend = mod(dayIndex-1,7) >= 5;

business = 1./(1+exp(-(hour-7))) .* 1./(1+exp(hour-20));
demand = 0.18 + 0.52*business;
demand(isWeekend) = 0.16 + 0.24*business(isWeekend);

noise = zeros(size(t));
for k=2:numel(t)
    noise(k)=0.995*noise(k-1)+0.005*randn;
end
demand = demand + 1.8*noise;

eventCode = zeros(size(t));
nJobs = max(4,round(days*2));
for j=1:nJobs
    start = randi([1,max(1,numel(t)-360)]);
    duration = randi([60,360]);
    stop = min(numel(t),start+duration);
    demand(start:stop)=demand(start:stop)+0.18+0.32*rand;
    eventCode(start:stop)=1; % unexpected compute job
end
demand = min(max(demand,0.05),1.0);

cpu1 = 20 + 185*demand;
cpu2 = 20 + 185*min(1,max(.05,demand + .04*randn(size(demand))));
serverFan = min(100,max(40,38 + 62*demand));
cracPWM = min(100,max(45,48 + 58*demand));
capacity = ones(size(t));

% One randomly located cooling derate; the command remains visible separately.
if numel(t)>2400
    start=randi([round(.2*numel(t)),round(.8*numel(t))]);
    duration=round((8*60+12*60*rand)/dt_s);
    stop=min(numel(t),start+duration);
    capacity(start:stop)=0.55+0.15*rand;
    eventCode(start:stop)=2; % CRAC capacity derate
end

supplyTemp = 22 + 0.35*sin(2*pi*(hour-14)/24) + 0.08*randn(size(t));
inputs=table(t,cpu1,cpu2,serverFan,cracPWM,capacity,supplyTemp,eventCode,...
    'VariableNames',{'time_s','CPU1_W_per_server','CPU2_W_per_server',...
    'ServerFanPWM_cmd_pct','CRAC_PWM_cmd_pct','CRAC_capacity_fraction',...
    'CRAC_supply_temp_C','EventCode'});
end
