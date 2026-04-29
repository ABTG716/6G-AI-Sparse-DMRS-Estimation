%% run_all_experiments.m
% Complete experiment matrix for 6G DMRS LLS validation and evaluation.
%
% Experiments 1-2: 16QAM r=0.48
%   1a: HARQ ON,  variable TBS    |  2a: HARQ ON,  fixed TBS
%   1b: HARQ OFF, variable TBS    |  2b: HARQ OFF, fixed TBS
%
% Experiments 3: 64QAM r=0.65
%   3a: HARQ ON,  variable TBS    |  3c: HARQ ON,  fixed TBS
%   3b: HARQ OFF, variable TBS    |  3d: HARQ OFF, fixed TBS
%
% Experiment 4: MSE across CDL-A/C/D
%
% Validation: Perfect vs Practical CE

clearvars; close all; clc;
addpath(genpath(pwd));
addpath('C:\Users\5g_lab\Documents\MATLAB\Examples\R2025b\pre6g\LinkLevelSimulationfor6GExample');

%% ===== Configuration =====
NFrames = 20;
SNRRange = -5:2:25;
patterns = {'nr_baseline', 'sparse_fd', 'sparse_td', 'sparse_fd_td'};
patternLabels = {'NR baseline (12 RE)', 'Sparse FD (8 RE)', 'Sparse TD (6 RE)', 'Sparse FD+TD (4 RE)'};
colors = {'b', 'r', 'g', 'm'};
markers = {'o', 's', 'd', '^'};

resultsDir = './results/experiments';
if ~exist(resultsDir, 'dir'); mkdir(resultsDir); end

%% Helper to build a valid field name from experiment + pattern
fname = @(expLabel, pat) sprintf('e_%s_%s', expLabel, pat);

%% ============================================================
%% VALIDATION: Perfect vs Practical CE
%% ============================================================
fprintf('\n========================================\n');
fprintf('VALIDATION: Perfect vs Practical CE\n');
fprintf('========================================\n');

val = struct();
for h = [true false]
    harqStr = ternary(h, 'HARQon', 'HARQoff');
    for isPerfect = [true false]
        ceStr = ternary(isPerfect, 'perfectCE', 'practicalCE');
        label = sprintf('%s_%s', harqStr, ceStr);
        fprintf('\n--- %s ---\n', label);
        
        simCfg = evm_pdsch_lls('NFrames', NFrames, 'SNRdB', SNRRange, ...
            'Modulation', '16QAM', 'TargetCodeRate', 490/1024, ...
            'EnableHARQ', h, 'PerfectChannelEstimation', isPerfect);
        dmrsCfg = dmrs_config('PDSCH', 'Pattern', 'nr_baseline');
        val.(fname('val', label)) = run_pdsch_lls(simCfg, dmrsCfg, 'Verbose', true);
    end
end

%% ============================================================
%% EXPERIMENTS 1a/1b: 16QAM, variable TBS, HARQ ON/OFF
%% ============================================================
fprintf('\n========================================\n');
fprintf('EXPERIMENTS 1a/1b: 16QAM, variable TBS\n');
fprintf('========================================\n');

exp1 = struct();
for h = [true false]
    expLabel = ternary(h, 'e1a', 'e1b');
    fprintf('\n=== %s ===\n', expLabel);
    for p = 1:numel(patterns)
        simCfg = evm_pdsch_lls('NFrames', NFrames, 'SNRdB', SNRRange, ...
            'Modulation', '16QAM', 'TargetCodeRate', 490/1024, ...
            'EnableHARQ', h, 'FixedTBS', false);
        dmrsCfg = dmrs_config('PDSCH', 'Pattern', patterns{p});
        fprintf('\n--- %s ---\n', patterns{p});
        exp1.(fname(expLabel, patterns{p})) = run_pdsch_lls(simCfg, dmrsCfg, 'Verbose', true);
    end
end

%% ============================================================
%% EXPERIMENTS 2a/2b: 16QAM, fixed TBS, HARQ ON/OFF
%% ============================================================
fprintf('\n========================================\n');
fprintf('EXPERIMENTS 2a/2b: 16QAM, fixed TBS\n');
fprintf('========================================\n');

exp2 = struct();
for h = [true false]
    expLabel = ternary(h, 'e2a', 'e2b');
    fprintf('\n=== %s ===\n', expLabel);
    for p = 1:numel(patterns)
        simCfg = evm_pdsch_lls('NFrames', NFrames, 'SNRdB', SNRRange, ...
            'Modulation', '16QAM', 'TargetCodeRate', 490/1024, ...
            'EnableHARQ', h, 'FixedTBS', true);
        dmrsCfg = dmrs_config('PDSCH', 'Pattern', patterns{p});
        fprintf('\n--- %s (FixedTBS) ---\n', patterns{p});
        exp2.(fname(expLabel, patterns{p})) = run_pdsch_lls(simCfg, dmrsCfg, 'Verbose', true);
    end
end

%% ============================================================
%% EXPERIMENTS 3a-3d: 64QAM r=0.65
%% ============================================================
fprintf('\n========================================\n');
fprintf('EXPERIMENTS 3a-3d: 64QAM r=0.65\n');
fprintf('========================================\n');

exp3 = struct();
configs3 = {
    true,  false, 'e3a';
    false, false, 'e3b';
    true,  true,  'e3c';
    false, true,  'e3d';
};

for c = 1:size(configs3, 1)
    harq = configs3{c, 1};
    fixTBS = configs3{c, 2};
    expLabel = configs3{c, 3};
    fprintf('\n=== %s (HARQ=%s, FixTBS=%s) ===\n', expLabel, ...
        ternary(harq, 'ON', 'OFF'), ternary(fixTBS, 'YES', 'NO'));
    
    for p = 1:numel(patterns)
        simCfg = evm_pdsch_lls('NFrames', NFrames, 'SNRdB', SNRRange, ...
            'Modulation', '64QAM', 'TargetCodeRate', 0.65, ...
            'EnableHARQ', harq, 'FixedTBS', fixTBS);
        dmrsCfg = dmrs_config('PDSCH', 'Pattern', patterns{p});
        fprintf('\n--- %s ---\n', patterns{p});
        exp3.(fname(expLabel, patterns{p})) = run_pdsch_lls(simCfg, dmrsCfg, 'Verbose', true);
    end
end

%% ============================================================
%% EXPERIMENT 4: MSE across channel models
%% ============================================================
fprintf('\n========================================\n');
fprintf('EXPERIMENT 4: MSE across channel models\n');
fprintf('========================================\n');

exp4 = struct();
channelModels = {'CDL-A', 'CDL-C', 'CDL-D'};

for ch = 1:numel(channelModels)
    chLabel = channelModels{ch}(end);  % 'A', 'C', 'D'
    fprintf('\n=== Channel: %s ===\n', channelModels{ch});
    for p = 1:numel(patterns)
        simCfg = evm_pdsch_lls('NFrames', NFrames, 'SNRdB', SNRRange, ...
            'Modulation', '16QAM', 'TargetCodeRate', 490/1024, ...
            'EnableHARQ', false, 'FixedTBS', false, ...
            'DelayProfile', channelModels{ch});
        dmrsCfg = dmrs_config('PDSCH', 'Pattern', patterns{p});
        fprintf('\n--- %s, %s ---\n', channelModels{ch}, patterns{p});
        exp4.(fname(chLabel, patterns{p})) = run_pdsch_lls(simCfg, dmrsCfg, 'Verbose', true);
    end
end

%% ============================================================
%% PLOTS
%% ============================================================
fprintf('\n========================================\n');
fprintf('GENERATING PLOTS\n');
fprintf('========================================\n');

%% --- Plot 1: 16QAM BLER 2x2 grid ---
figure('Position', [50 50 1400 900]);
plotCfg = {
    exp1, 'e1a', 'Exp 1a: HARQ ON, Variable TBS';
    exp1, 'e1b', 'Exp 1b: HARQ OFF, Variable TBS';
    exp2, 'e2a', 'Exp 2a: HARQ ON, Fixed TBS';
    exp2, 'e2b', 'Exp 2b: HARQ OFF, Fixed TBS';
};
for sp = 1:4
    subplot(2, 2, sp); hold on; grid on;
    for p = 1:numel(patterns)
        r = plotCfg{sp,1}.(fname(plotCfg{sp,2}, patterns{p}));
        semilogy(r.SNRdB, max(r.BLER, 1e-4), ...
            [colors{p} '-' markers{p}], 'LineWidth', 1.5, 'MarkerSize', 4);
    end
    xlabel('SNR (dB)'); ylabel('BLER');
    title(plotCfg{sp,3}); ylim([1e-4 1]);
    legend(patternLabels, 'Location', 'southwest', 'FontSize', 7);
end
sgtitle('16QAM r=0.48 — BLER (Final, after HARQ)');
saveas(gcf, fullfile(resultsDir, 'plot1_16QAM_BLER_2x2.png'));

%% --- Plot 2: 16QAM Initial BLER 2x2 grid (HARQ analysis) ---
figure('Position', [50 50 1400 900]);
for sp = 1:4
    subplot(2, 2, sp); hold on; grid on;
    for p = 1:numel(patterns)
        r = plotCfg{sp,1}.(fname(plotCfg{sp,2}, patterns{p}));
        semilogy(r.SNRdB, max(r.InitialBLER, 1e-4), ...
            [colors{p} '-' markers{p}], 'LineWidth', 1.5, 'MarkerSize', 4);
    end
    xlabel('SNR (dB)'); ylabel('Initial Tx BLER');
    title(plotCfg{sp,3}); ylim([1e-4 1]);
    legend(patternLabels, 'Location', 'southwest', 'FontSize', 7);
end
sgtitle('16QAM r=0.48 — Initial Transmission BLER (before HARQ)');
saveas(gcf, fullfile(resultsDir, 'plot2_16QAM_InitBLER_2x2.png'));

%% --- Plot 3: 16QAM Throughput (Mbps) 2x2 grid ---
figure('Position', [50 50 1400 900]);
for sp = 1:4
    subplot(2, 2, sp); hold on; grid on;
    for p = 1:numel(patterns)
        r = plotCfg{sp,1}.(fname(plotCfg{sp,2}, patterns{p}));
        plot(r.SNRdB, r.ThroughputMbps, ...
            [colors{p} '-' markers{p}], 'LineWidth', 1.5, 'MarkerSize', 4);
    end
    xlabel('SNR (dB)'); ylabel('Throughput (Mbps)');
    title(plotCfg{sp,3});
    legend(patternLabels, 'Location', 'southeast', 'FontSize', 7);
end
sgtitle('16QAM r=0.48 — Throughput (Mbps)');
saveas(gcf, fullfile(resultsDir, 'plot3_16QAM_Tput_2x2.png'));

%% --- Plot 4: 16QAM MSE ---
figure('Position', [50 50 700 500]);
hold on; grid on;
for p = 1:numel(patterns)
    r = exp1.(fname('e1b', patterns{p}));
    semilogy(r.SNRdB, max(r.MSE_channelEst, 1e-8), ...
        [colors{p} '-' markers{p}], 'LineWidth', 1.5, 'MarkerSize', 5);
end
xlabel('SNR (dB)'); ylabel('Channel Estimation MSE');
legend(patternLabels, 'Location', 'northeast');
title('16QAM — Channel Estimation MSE');
saveas(gcf, fullfile(resultsDir, 'plot4_16QAM_MSE.png'));

%% --- Plot 5: 16QAM HARQ Retransmissions ---
figure('Position', [50 50 1400 450]);
for sp = 1:2
    subplot(1, 2, sp); hold on; grid on;
    idx = ternary(sp==1, 1, 2);  % 1a or 1b
    for p = 1:numel(patterns)
        r = plotCfg{idx,1}.(fname(plotCfg{idx,2}, patterns{p}));
        plot(r.SNRdB, r.NumRetransmissions, ...
            [colors{p} '-' markers{p}], 'LineWidth', 1.5, 'MarkerSize', 4);
    end
    xlabel('SNR (dB)'); ylabel('Number of Retransmissions');
    title(plotCfg{idx,3});
    legend(patternLabels, 'Location', 'northeast', 'FontSize', 7);
end
sgtitle('16QAM — HARQ Retransmission Count');
saveas(gcf, fullfile(resultsDir, 'plot5_16QAM_HARQ_retx.png'));

%% --- Plot 6: 64QAM BLER 2x2 grid ---
figure('Position', [50 50 1400 900]);
plotCfg3 = {
    exp3, 'e3a', 'Exp 3a: HARQ ON, Variable TBS';
    exp3, 'e3b', 'Exp 3b: HARQ OFF, Variable TBS';
    exp3, 'e3c', 'Exp 3c: HARQ ON, Fixed TBS';
    exp3, 'e3d', 'Exp 3d: HARQ OFF, Fixed TBS';
};
for sp = 1:4
    subplot(2, 2, sp); hold on; grid on;
    for p = 1:numel(patterns)
        r = plotCfg3{sp,1}.(fname(plotCfg3{sp,2}, patterns{p}));
        semilogy(r.SNRdB, max(r.BLER, 1e-4), ...
            [colors{p} '-' markers{p}], 'LineWidth', 1.5, 'MarkerSize', 4);
    end
    xlabel('SNR (dB)'); ylabel('BLER');
    title(plotCfg3{sp,3}); ylim([1e-4 1]);
    legend(patternLabels, 'Location', 'southwest', 'FontSize', 7);
end
sgtitle('64QAM r=0.65 — BLER (Final, after HARQ)');
saveas(gcf, fullfile(resultsDir, 'plot6_64QAM_BLER_2x2.png'));

%% --- Plot 7: 64QAM Initial BLER 2x2 grid ---
figure('Position', [50 50 1400 900]);
for sp = 1:4
    subplot(2, 2, sp); hold on; grid on;
    for p = 1:numel(patterns)
        r = plotCfg3{sp,1}.(fname(plotCfg3{sp,2}, patterns{p}));
        semilogy(r.SNRdB, max(r.InitialBLER, 1e-4), ...
            [colors{p} '-' markers{p}], 'LineWidth', 1.5, 'MarkerSize', 4);
    end
    xlabel('SNR (dB)'); ylabel('Initial Tx BLER');
    title(plotCfg3{sp,3}); ylim([1e-4 1]);
    legend(patternLabels, 'Location', 'southwest', 'FontSize', 7);
end
sgtitle('64QAM r=0.65 — Initial Transmission BLER (before HARQ)');
saveas(gcf, fullfile(resultsDir, 'plot7_64QAM_InitBLER_2x2.png'));

%% --- Plot 8: 64QAM Throughput 2x2 grid ---
figure('Position', [50 50 1400 900]);
for sp = 1:4
    subplot(2, 2, sp); hold on; grid on;
    for p = 1:numel(patterns)
        r = plotCfg3{sp,1}.(fname(plotCfg3{sp,2}, patterns{p}));
        plot(r.SNRdB, r.ThroughputMbps, ...
            [colors{p} '-' markers{p}], 'LineWidth', 1.5, 'MarkerSize', 4);
    end
    xlabel('SNR (dB)'); ylabel('Throughput (Mbps)');
    title(plotCfg3{sp,3});
    legend(patternLabels, 'Location', 'southeast', 'FontSize', 7);
end
sgtitle('64QAM r=0.65 — Throughput (Mbps)');
saveas(gcf, fullfile(resultsDir, 'plot8_64QAM_Tput_2x2.png'));

%% --- Plot 9: 64QAM MSE ---
figure('Position', [50 50 700 500]);
hold on; grid on;
for p = 1:numel(patterns)
    r = exp3.(fname('e3b', patterns{p}));
    semilogy(r.SNRdB, max(r.MSE_channelEst, 1e-8), ...
        [colors{p} '-' markers{p}], 'LineWidth', 1.5, 'MarkerSize', 5);
end
xlabel('SNR (dB)'); ylabel('Channel Estimation MSE');
legend(patternLabels, 'Location', 'northeast');
title('64QAM — Channel Estimation MSE');
saveas(gcf, fullfile(resultsDir, 'plot9_64QAM_MSE.png'));

%% --- Plot 10: MSE across channel models ---
figure('Position', [50 50 1400 400]);
for ch = 1:numel(channelModels)
    chLabel = channelModels{ch}(end);
    subplot(1, 3, ch); hold on; grid on;
    for p = 1:numel(patterns)
        r = exp4.(fname(chLabel, patterns{p}));
        semilogy(r.SNRdB, max(r.MSE_channelEst, 1e-8), ...
            [colors{p} '-' markers{p}], 'LineWidth', 1.5, 'MarkerSize', 5);
    end
    xlabel('SNR (dB)'); ylabel('MSE');
    title(sprintf('%s, DS=100ns', channelModels{ch}));
    legend(patternLabels, 'Location', 'northeast', 'FontSize', 7);
end
sgtitle('CE MSE across Channel Models — 16QAM, HARQ OFF');
saveas(gcf, fullfile(resultsDir, 'plot10_MSE_channel_models.png'));

%% --- Plot 11: Validation — Perfect vs Practical CE ---
figure('Position', [50 50 1200 500]);
for v = 1:2
    subplot(1, 2, v); hold on; grid on;
    harqStr = ternary(v==1, 'HARQon', 'HARQoff');
    r_perf = val.(fname('val', [harqStr '_perfectCE']));
    r_prac = val.(fname('val', [harqStr '_practicalCE']));
    semilogy(r_perf.SNRdB, max(r_perf.BLER, 1e-4), 'b-o', ...
             r_prac.SNRdB, max(r_prac.BLER, 1e-4), 'r-s', ...
             'LineWidth', 1.5, 'MarkerSize', 4);
    xlabel('SNR (dB)'); ylabel('BLER'); ylim([1e-4 1]);
    legend('Perfect CE', 'Practical CE', 'Location', 'southwest');
    title(sprintf('HARQ %s', ternary(v==1, 'ON', 'OFF')));
end
sgtitle('Validation: Perfect vs Practical CE — 16QAM, NR Baseline');
saveas(gcf, fullfile(resultsDir, 'plot11_validation.png'));

%% ============================================================
%% SUMMARY TABLES
%% ============================================================
fprintf('\n========================================\n');
fprintf('SUMMARY TABLES\n');
fprintf('========================================\n');

% --- Table 1: SNR at 10% BLER (final, after HARQ) ---
fprintf('\n--- Table 1: SNR (dB) at 10%% Final BLER ---\n');
fprintf('%30s | %12s %12s %12s %12s\n', 'Experiment', patternLabels{:});
fprintf('%s\n', repmat('-', 1, 82));

allExps = {
    'Exp1a: 16Q HARQon  varTBS', exp1, 'e1a';
    'Exp1b: 16Q HARQoff varTBS', exp1, 'e1b';
    'Exp2a: 16Q HARQon  fixTBS', exp2, 'e2a';
    'Exp2b: 16Q HARQoff fixTBS', exp2, 'e2b';
    'Exp3a: 64Q HARQon  varTBS', exp3, 'e3a';
    'Exp3b: 64Q HARQoff varTBS', exp3, 'e3b';
    'Exp3c: 64Q HARQon  fixTBS', exp3, 'e3c';
    'Exp3d: 64Q HARQoff fixTBS', exp3, 'e3d';
};
for e = 1:size(allExps, 1)
    fprintf('%30s |', allExps{e,1});
    for p = 1:numel(patterns)
        r = allExps{e,2}.(fname(allExps{e,3}, patterns{p}));
        snr10 = find_snr_at_bler(r.SNRdB, r.BLER, 0.10);
        fprintf(' %11.1f ', snr10);
    end
    fprintf('\n');
end

% --- Table 2: SNR at 10% Initial BLER (before HARQ) ---
fprintf('\n--- Table 2: SNR (dB) at 10%% Initial Tx BLER ---\n');
fprintf('%30s | %12s %12s %12s %12s\n', 'Experiment', patternLabels{:});
fprintf('%s\n', repmat('-', 1, 82));
for e = 1:size(allExps, 1)
    fprintf('%30s |', allExps{e,1});
    for p = 1:numel(patterns)
        r = allExps{e,2}.(fname(allExps{e,3}, patterns{p}));
        snr10 = find_snr_at_bler(r.SNRdB, r.InitialBLER, 0.10);
        fprintf(' %11.1f ', snr10);
    end
    fprintf('\n');
end

% --- Table 3: CE MSE at selected SNR points ---
fprintf('\n--- Table 3: CE MSE at SNR = {0, 5, 10, 15, 20} dB (16QAM, HARQ OFF, var TBS) ---\n');
snrPoints = [0 5 10 15 20];
fprintf('%20s |', 'Pattern');
for s = snrPoints; fprintf(' %10d dB', s); end
fprintf('\n%s\n', repmat('-', 1, 80));
for p = 1:numel(patterns)
    r = exp1.(fname('e1b', patterns{p}));
    fprintf('%20s |', patternLabels{p});
    for s = snrPoints
        idx = find(abs(r.SNRdB - s) < 0.5, 1);
        if ~isempty(idx)
            fprintf(' %12.2e', r.MSE_channelEst(idx));
        else
            fprintf(' %12s', 'N/A');
        end
    end
    fprintf('\n');
end

% --- Table 4: CE MSE across channel models at SNR=10 dB ---
fprintf('\n--- Table 4: CE MSE at SNR=10 dB across channel models ---\n');
fprintf('%20s |', 'Pattern');
for ch = 1:numel(channelModels); fprintf(' %12s', channelModels{ch}); end
fprintf('\n%s\n', repmat('-', 1, 60));
for p = 1:numel(patterns)
    fprintf('%20s |', patternLabels{p});
    for ch = 1:numel(channelModels)
        chLabel = channelModels{ch}(end);
        r = exp4.(fname(chLabel, patterns{p}));
        idx = find(abs(r.SNRdB - 10) < 0.5, 1);
        if ~isempty(idx)
            fprintf(' %12.2e', r.MSE_channelEst(idx));
        else
            fprintf(' %12s', 'N/A');
        end
    end
    fprintf('\n');
end

% --- Table 5: HARQ Retransmission summary at SNR = {-3, 0, 3, 5, 10} dB ---
fprintf('\n--- Table 5: HARQ Retransmissions (16QAM, HARQ ON, var TBS) ---\n');
harqSNRs = [-3 0 3 5 10];
fprintf('%20s | SNR:', 'Pattern');
for s = harqSNRs; fprintf(' %6d dB', s); end
fprintf('\n%s\n', repmat('-', 1, 70));
for p = 1:numel(patterns)
    r = exp1.(fname('e1a', patterns{p}));
    fprintf('%20s |  ReTx:', patternLabels{p});
    for s = harqSNRs
        idx = find(abs(r.SNRdB - s) < 0.5, 1);
        if ~isempty(idx)
            fprintf(' %8d', r.NumRetransmissions(idx));
        else
            fprintf(' %8s', 'N/A');
        end
    end
    fprintf('\n%20s | Init%%:', '');
    for s = harqSNRs
        idx = find(abs(r.SNRdB - s) < 0.5, 1);
        if ~isempty(idx)
            fprintf(' %7.1f%%', r.InitialBLER(idx)*100);
        else
            fprintf(' %8s', 'N/A');
        end
    end
    fprintf('\n');
end

%% ===== Save everything =====
save(fullfile(resultsDir, 'all_experiments.mat'), ...
    'val', 'exp1', 'exp2', 'exp3', 'exp4', ...
    'patterns', 'patternLabels', 'SNRRange', 'NFrames');
fprintf('\n\nAll results saved to %s\n', resultsDir);
fprintf('All plots saved as PNG.\n');
fprintf('DONE.\n');

%% ============================================================
%% LOCAL FUNCTIONS
%% ============================================================

function snr = find_snr_at_bler(snrVec, blerVec, targetBler)
    idx = find(blerVec <= targetBler, 1, 'first');
    if isempty(idx)
        snr = NaN;
    elseif idx == 1
        snr = snrVec(1);
    else
        b1 = blerVec(idx-1); b2 = blerVec(idx);
        s1 = snrVec(idx-1);  s2 = snrVec(idx);
        if b1 == b2
            snr = s1;
        else
            snr = s1 + (s2 - s1) * (b1 - targetBler) / (b1 - b2);
        end
    end
end

function result = ternary(condition, trueVal, falseVal)
    if condition
        result = trueVal;
    else
        result = falseVal;
    end
end
