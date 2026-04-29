%% run_experiments.m
% Comprehensive experiment suite for 6G DMRS evaluation.
%
% Experiment matrix:
%   Exp 1a: HARQ ON,  variable TBS, 16QAM r=0.48
%   Exp 1b: HARQ OFF, variable TBS, 16QAM r=0.48
%   Exp 2a: HARQ ON,  fixed TBS,    16QAM r=0.48
%   Exp 2b: HARQ OFF, fixed TBS,    16QAM r=0.48
%   Exp 3a: HARQ ON,  variable TBS, 64QAM r=0.65
%   Exp 3b: HARQ OFF, variable TBS, 64QAM r=0.65
%   Exp 3c: HARQ ON,  fixed TBS,    64QAM r=0.65
%   Exp 3d: HARQ OFF, fixed TBS,    64QAM r=0.65
%   Exp 4:  MSE across CDL-A/C/D (HARQ OFF, variable TBS, 16QAM)
%
% All experiments use 4 DMRS patterns, CDL-C 100ns, 4x2 MIMO, 30 kHz SCS.

clearvars; close all; clc;
addpath(genpath(pwd));

%% ===== Configuration =====
nFrames = 20;           % 20 frames for reliable statistics
snrRange = -5:2:25;
patterns = {'nr_baseline', 'sparse_half_fd', 'sparse_td', 'sparse_fd_td'};
patternLabels = {'NR baseline', 'Sparse half FD', 'Sparse TD', 'Sparse FD+TD'};
colors = {'b', 'r', 'g', 'm'};

% Common parameters
commonParams = {
    'CarrierFreq', 4e9, ...
    'SubcarrierSpacing', 30, ...
    'BandwidthMHz', 20, ...
    'DelayProfile', 'CDL-C', ...
    'DelaySpread', 100e-9, ...
    'UESpeed_kmh', 30, ...
    'NTxAnts', 4, ...
    'NRxAnts', 2, ...
    'NumLayers', 1, ...
    'NFrames', nFrames, ...
    'SNRdB', snrRange ...
};

%% ===== Define Experiments =====
experiments = struct();

% --- 16QAM experiments ---
experiments(1).name = '1a_HARQ_ON_varTBS_16QAM';
experiments(1).label = 'HARQ ON, Variable TBS, 16QAM';
experiments(1).params = [commonParams, 'Modulation','16QAM','TargetCodeRate',490/1024,'EnableHARQ',true,'FixedTBS',false];

experiments(2).name = '1b_HARQ_OFF_varTBS_16QAM';
experiments(2).label = 'HARQ OFF, Variable TBS, 16QAM';
experiments(2).params = [commonParams, 'Modulation','16QAM','TargetCodeRate',490/1024,'EnableHARQ',false,'FixedTBS',false];

experiments(3).name = '2a_HARQ_ON_fixTBS_16QAM';
experiments(3).label = 'HARQ ON, Fixed TBS, 16QAM';
experiments(3).params = [commonParams, 'Modulation','16QAM','TargetCodeRate',490/1024,'EnableHARQ',true,'FixedTBS',true];

experiments(4).name = '2b_HARQ_OFF_fixTBS_16QAM';
experiments(4).label = 'HARQ OFF, Fixed TBS, 16QAM';
experiments(4).params = [commonParams, 'Modulation','16QAM','TargetCodeRate',490/1024,'EnableHARQ',false,'FixedTBS',true];

% --- 64QAM experiments ---
experiments(5).name = '3a_HARQ_ON_varTBS_64QAM';
experiments(5).label = 'HARQ ON, Variable TBS, 64QAM';
experiments(5).params = [commonParams, 'Modulation','64QAM','TargetCodeRate',666/1024,'EnableHARQ',true,'FixedTBS',false];

experiments(6).name = '3b_HARQ_OFF_varTBS_64QAM';
experiments(6).label = 'HARQ OFF, Variable TBS, 64QAM';
experiments(6).params = [commonParams, 'Modulation','64QAM','TargetCodeRate',666/1024,'EnableHARQ',false,'FixedTBS',false];

experiments(7).name = '3c_HARQ_ON_fixTBS_64QAM';
experiments(7).label = 'HARQ ON, Fixed TBS, 64QAM';
experiments(7).params = [commonParams, 'Modulation','64QAM','TargetCodeRate',666/1024,'EnableHARQ',true,'FixedTBS',true];

experiments(8).name = '3d_HARQ_OFF_fixTBS_64QAM';
experiments(8).label = 'HARQ OFF, Fixed TBS, 64QAM';
experiments(8).params = [commonParams, 'Modulation','64QAM','TargetCodeRate',666/1024,'EnableHARQ',false,'FixedTBS',true];

%% ===== Run All Experiments =====
resultsDir = './results/experiments';
if ~exist(resultsDir, 'dir'); mkdir(resultsDir); end

allExpResults = struct();

for e = 1:numel(experiments)
    fprintf('\n========================================\n');
    fprintf('Experiment %s\n', experiments(e).label);
    fprintf('========================================\n');
    
    simCfg = evm_pdsch_lls(experiments(e).params{:});
    expResults = struct();
    
    for p = 1:numel(patterns)
        dmrsCfg = dmrs_config('PDSCH', 'Pattern', patterns{p});
        fprintf('\n--- %s (%s) ---\n', patterns{p}, dmrsCfg.OverheadInfo.Description);
        
        expResults.(patterns{p}) = run_pdsch_lls(simCfg, dmrsCfg, 'Verbose', true);
    end
    
    allExpResults.(experiments(e).name) = expResults;
    
    % Save incrementally
    save(fullfile(resultsDir, [experiments(e).name '.mat']), 'expResults', 'simCfg', 'patterns');
end

%% ===== Experiment 4: MSE across channel models =====
fprintf('\n========================================\n');
fprintf('Experiment 4: MSE across CDL-A/C/D\n');
fprintf('========================================\n');

channelModels = {'CDL-A', 'CDL-C', 'CDL-D'};
exp4Results = struct();

for c = 1:numel(channelModels)
    fprintf('\n--- Channel Model: %s ---\n', channelModels{c});
    simCfg = evm_pdsch_lls(commonParams{:}, ...
        'Modulation', '16QAM', 'TargetCodeRate', 490/1024, ...
        'EnableHARQ', false, 'FixedTBS', false, ...
        'DelayProfile', channelModels{c});
    
    for p = 1:numel(patterns)
        dmrsCfg = dmrs_config('PDSCH', 'Pattern', patterns{p});
        fprintf('  %s: ', patterns{p});
        r = run_pdsch_lls(simCfg, dmrsCfg, 'Verbose', true);
        exp4Results.(channelModels{c}).(patterns{p}) = r;
    end
end
allExpResults.exp4_MSE_channels = exp4Results;

% Save all results
save(fullfile(resultsDir, 'all_experiments.mat'), 'allExpResults', 'experiments', 'patterns', 'patternLabels');

%% ===== Generate Plots =====
fprintf('\n\n========================================\n');
fprintf('Generating Plots\n');
fprintf('========================================\n');

% --- Plot A: 16QAM BLER, 2x2 grid (HARQ × TBS) ---
figure('Position', [50 50 1200 800]);
plotConfigs = {
    '1a_HARQ_ON_varTBS_16QAM',  'HARQ ON, Variable TBS';
    '1b_HARQ_OFF_varTBS_16QAM', 'HARQ OFF, Variable TBS';
    '2a_HARQ_ON_fixTBS_16QAM',  'HARQ ON, Fixed TBS';
    '2b_HARQ_OFF_fixTBS_16QAM', 'HARQ OFF, Fixed TBS';
};
for sp = 1:4
    subplot(2,2,sp); hold on; grid on;
    expName = plotConfigs{sp,1};
    for p = 1:numel(patterns)
        r = allExpResults.(expName).(patterns{p});
        semilogy(r.SNRdB, max(r.BLER, 1e-4), [colors{p} '-o'], ...
            'LineWidth', 1.5, 'MarkerSize', 4);
    end
    xlabel('SNR (dB)'); ylabel('BLER');
    title(plotConfigs{sp,2});
    if sp == 1; legend(patternLabels, 'Location', 'southwest'); end
    ylim([1e-4 1]);
end
sgtitle('16QAM: BLER vs SNR — HARQ × TBS Comparison', 'FontWeight', 'bold');
saveas(gcf, fullfile(resultsDir, 'PlotA_16QAM_BLER.png'));

% --- Plot B: 16QAM Throughput (Mbps), 2x2 grid ---
figure('Position', [50 50 1200 800]);
for sp = 1:4
    subplot(2,2,sp); hold on; grid on;
    expName = plotConfigs{sp,1};
    for p = 1:numel(patterns)
        r = allExpResults.(expName).(patterns{p});
        plot(r.SNRdB, r.ThroughputMbps, [colors{p} '-o'], ...
            'LineWidth', 1.5, 'MarkerSize', 4);
    end
    xlabel('SNR (dB)'); ylabel('Throughput (Mbps)');
    title(plotConfigs{sp,2});
    if sp == 1; legend(patternLabels, 'Location', 'southeast'); end
end
sgtitle('16QAM: Throughput vs SNR — HARQ × TBS Comparison', 'FontWeight', 'bold');
saveas(gcf, fullfile(resultsDir, 'PlotB_16QAM_Throughput.png'));

% --- Plot C: MSE vs SNR (one plot, patterns only — MSE is independent of HARQ/TBS) ---
figure('Position', [50 50 600 400]);
hold on; grid on;
expName = '1b_HARQ_OFF_varTBS_16QAM';  % Use HARQ OFF for cleaner MSE
for p = 1:numel(patterns)
    r = allExpResults.(expName).(patterns{p});
    semilogy(r.SNRdB, max(r.MSE_channelEst, 1e-8), [colors{p} '-o'], ...
        'LineWidth', 1.5, 'MarkerSize', 4);
end
xlabel('SNR (dB)'); ylabel('Channel Estimation MSE');
legend(patternLabels, 'Location', 'northeast');
title('16QAM: Channel Estimation MSE vs SNR');
saveas(gcf, fullfile(resultsDir, 'PlotC_16QAM_MSE.png'));

% --- Plot D: 64QAM BLER, 2x2 grid ---
figure('Position', [50 50 1200 800]);
plotConfigs64 = {
    '3a_HARQ_ON_varTBS_64QAM',  'HARQ ON, Variable TBS';
    '3b_HARQ_OFF_varTBS_64QAM', 'HARQ OFF, Variable TBS';
    '3c_HARQ_ON_fixTBS_64QAM',  'HARQ ON, Fixed TBS';
    '3d_HARQ_OFF_fixTBS_64QAM', 'HARQ OFF, Fixed TBS';
};
for sp = 1:4
    subplot(2,2,sp); hold on; grid on;
    expName = plotConfigs64{sp,1};
    for p = 1:numel(patterns)
        r = allExpResults.(expName).(patterns{p});
        semilogy(r.SNRdB, max(r.BLER, 1e-4), [colors{p} '-o'], ...
            'LineWidth', 1.5, 'MarkerSize', 4);
    end
    xlabel('SNR (dB)'); ylabel('BLER');
    title(plotConfigs64{sp,2});
    if sp == 1; legend(patternLabels, 'Location', 'southwest'); end
    ylim([1e-4 1]);
end
sgtitle('64QAM: BLER vs SNR — HARQ × TBS Comparison', 'FontWeight', 'bold');
saveas(gcf, fullfile(resultsDir, 'PlotD_64QAM_BLER.png'));

% --- Plot E: 64QAM Throughput (Mbps), 2x2 grid ---
figure('Position', [50 50 1200 800]);
for sp = 1:4
    subplot(2,2,sp); hold on; grid on;
    expName = plotConfigs64{sp,1};
    for p = 1:numel(patterns)
        r = allExpResults.(expName).(patterns{p});
        plot(r.SNRdB, r.ThroughputMbps, [colors{p} '-o'], ...
            'LineWidth', 1.5, 'MarkerSize', 4);
    end
    xlabel('SNR (dB)'); ylabel('Throughput (Mbps)');
    title(plotConfigs64{sp,2});
    if sp == 1; legend(patternLabels, 'Location', 'southeast'); end
end
sgtitle('64QAM: Throughput vs SNR — HARQ × TBS Comparison', 'FontWeight', 'bold');
saveas(gcf, fullfile(resultsDir, 'PlotE_64QAM_Throughput.png'));

% --- Experiment 4: MSE Table across channel models ---
fprintf('\n\n===== Experiment 4: MSE Table =====\n');
snrPoints = [0 5 10 15 20];
fprintf('%20s', 'Pattern');
for c = 1:numel(channelModels)
    for s = 1:numel(snrPoints)
        fprintf(' | %s@%ddB', channelModels{c}, snrPoints(s));
    end
end
fprintf('\n');
fprintf('%s\n', repmat('-', 1, 20 + numel(channelModels)*numel(snrPoints)*12));
for p = 1:numel(patterns)
    fprintf('%20s', patterns{p});
    for c = 1:numel(channelModels)
        r = exp4Results.(channelModels{c}).(patterns{p});
        for s = 1:numel(snrPoints)
            snrIdx = find(r.SNRdB == snrPoints(s), 1);
            if ~isempty(snrIdx)
                fprintf(' | %10.2e', r.MSE_channelEst(snrIdx));
            else
                fprintf(' | %10s', 'N/A');
            end
        end
    end
    fprintf('\n');
end

fprintf('\n\nAll experiments complete. Results saved to %s\n', resultsDir);
