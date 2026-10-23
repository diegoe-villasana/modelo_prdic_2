function summary = run_week_validation()
%RUN_WEEK_VALIDATION Code-only seven-day regression for the V9 room plant.
root=fileparts(mfilename('fullpath'));
inputs=generate_week_profile(7,5,20260928);
model=import_crac_cfd(fullfile(root,'data'));
tic;
results=simulate_olympus_twin(inputs,model.model);
runtime=toc;
assert(height(results)==height(inputs) && all(results.DataValid));
assert(all(isfinite(results.CPU1_die_est_C)) && all(isfinite(results.CPU2_die_est_C)));
assert(all(results.Rack_demand_flow_m3_s>=0));
assert(all(results.Recirculation_fraction>=0 & results.Recirculation_fraction<=1));
out=fullfile(root,'output');if ~exist(out,'dir'),mkdir(out);end
writetable(results,fullfile(out,'v9_week_results.csv'));
summary=struct('status','PASS','samples',height(results),...
    'simulated_days',7,'sample_interval_s',5,'runtime_s',runtime,...
    'peak_CPU_die_est_C',max([results.CPU1_die_est_C;results.CPU2_die_est_C]),...
    'peak_rack_inlet_C',max(results.Rack_inlet_C),...
    'alarm_samples',sum(results.ThermalAlarm),...
    'model','V9 CFD flow interpolation; thermal R/C provisional',...
    'source_table','data/server_v9_fan_sweep.csv');
fid=fopen(fullfile(out,'v9_week_summary.json'),'w');
fprintf(fid,'%s\n',jsonencode(summary,'PrettyPrint',true));fclose(fid);
disp(summary);
end
