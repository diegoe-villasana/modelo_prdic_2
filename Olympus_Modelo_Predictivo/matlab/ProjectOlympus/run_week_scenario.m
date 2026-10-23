function results = run_week_scenario(seed)
%RUN_WEEK_SCENARIO Run a new seven-day plant simulation and export its signals.
if nargin<1, seed=[]; end
root=fileparts(mfilename('fullpath'));
model=import_crac_cfd(fullfile(root,'data'));
inputs=generate_week_profile(7,5,seed);
results=simulate_olympus_twin(inputs,model.model);
outDir=fullfile(root,'output'); if ~exist(outDir,'dir'), mkdir(outDir); end
writetable(inputs,fullfile(outDir,'olympus_inputs_week.csv'));
writetable(results,fullfile(outDir,'olympus_outputs_week.csv'));
save(fullfile(outDir,'olympus_week.mat'),'inputs','results','model','-v7.3');

f=figure('Visible','off','Position',[100 100 1200 800]);
tiledlayout(3,1);
nexttile; plot(results.time_s/86400,results.CPU1_W_per_server,results.time_s/86400,results.CPU2_W_per_server); ylabel('CPU W'); legend('CPU1','CPU2'); grid on;
nexttile; plot(results.time_s/86400,results.Rack_inlet_C,results.time_s/86400,results.Rack_outlet_C,results.time_s/86400,results.CPU1_die_est_C); ylabel('Temperature °C'); legend('Rack inlet','Rack outlet','CPU1 die estimate'); grid on;
nexttile; plot(results.time_s/86400,results.CRAC_PWM_cmd_pct,results.time_s/86400,100*results.Recirculation_fraction); ylabel('%'); xlabel('Day'); legend('CRAC command','Recirculation'); grid on;
exportgraphics(f,fullfile(outDir,'olympus_week_overview.png'),'Resolution',180); close(f);

fprintf('Samples: %d\n',height(results));
fprintf('Peak CPU estimate: %.2f C\n',max([results.CPU1_die_est_C;results.CPU2_die_est_C]));
fprintf('Peak rack inlet: %.2f C\n',max(results.Rack_inlet_C));
fprintf('Alarm samples: %d\n',sum(results.ThermalAlarm));
end
