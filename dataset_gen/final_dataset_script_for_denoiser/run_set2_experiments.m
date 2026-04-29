%% run_set2_experiments.m
% Set 2: Speed sweep, delay spread sweep, and resource grid visualization.
%
% All experiments: 64QAM r=0.65, HARQ OFF, Fixed TBS, CDL-C
% 50 frames for statistical reliability
%
% S2-A: Speed sweep (DS=100ns, speed=3/30/120/500 km/h)
% S2-B: Delay spread sweep (speed=30km/h, DS=30/100/300/1000 ns)
% S2-C: Corner cases (easy: 3km/h+30ns, hard: 500km/h+300ns)

clearvars; close all; clc;
addpath(genpath(pwd));
addpath('C:\Users\5g_lab\Documents\MATLAB\Examples\R2025b\pre6g\LinkLevelSimulationfor6GExample');

%% ===== Configuration =====
NFrames = 50;
SNRRange = -5:2:30;     % Extended to 30 dB for 64QAM
patterns = {'nr_baseline', 'sparse_fd', 'sparse_td', 'sparse_fd_td'};
patternLabels = {'NR baseline (12 RE)', 'Sparse FD (8 RE)', 'Sparse TD (6 RE)', 'Sparse FD+TD (4 RE)'};
colors = {'b', 'r', 'g', 'm'};
markers = {'o', 's', 'd', '^'};

resultsDir = './results/set2';
if ~exist(resultsDir, 'dir'); mkdir(resultsDir); end

fname = @(prefix, pat) sprintf('e_%s_%s', prefix, pat);

%% ============================================================
%% PLOT S2-1: Resource Grid Visualization (no simulation needed)
%% ============================================================
fprintf('Generating resource grid visualization...\n');

carrier = pre6GCarrierConfig;
carrier.NSizeGrid = 51;
carrier.SubcarrierSpacing = 30;

nSC_show = 12;  % 1 PRB
nSym = carrier.SymbolsPerSlot;
K = carrier.NSizeGrid * 12;

figure('Position', [50 50 1600 500]);
for p = 1:numel(patterns)
    dmrsCfg = dmrs_config('PDSCH', 'Pattern', patterns{p});
    
    pdsch_vis = pre6GPDSCHConfig;
    pdsch_vis.PRBSet = 0:carrier.NSizeGrid-1;
    pdsch_vis.SymbolAllocation = [0, nSym];
    pdsch_vis.NumLayers = 1;
    pdsch_vis.Modulation = '16QAM';
    pdsch_vis.DMRS.DMRSConfigurationType = dmrsCfg.DMRSConfigurationType;
    pdsch_vis.DMRS.DMRSLength = dmrsCfg.DMRSLength;
    pdsch_vis.DMRS.DMRSAdditionalPosition = dmrsCfg.DMRSAdditionalPosition;
    pdsch_vis.DMRS.DMRSTypeAPosition = dmrsCfg.DMRSTypeAPosition;
    pdsch_vis.DMRS.NumCDMGroupsWithoutData = dmrsCfg.NumCDMGroupsWithoutData;
    pdsch_vis.DMRS.DMRSPortSet = dmrsCfg.DMRSPortSet;
    
    dmrsInd = hpre6GPDSCHDMRSIndices(carrier, pdsch_vis);
    dataInd = hpre6GPDSCHIndices(carrier, pdsch_vis);
    
    gridImg = zeros(nSC_show, nSym);
    
    % Map data REs
    [sc, sym] = ind2sub([K nSym], dataInd(:,1));
    for j = 1:numel(sc)
        if sc(j) <= nSC_show
            gridImg(sc(j), sym(j)) = 1;
        end
    end
    
    % Map DMRS REs (overwrite data)
    [sc, sym] = ind2sub([K nSym], dmrsInd(:,1));
    for j = 1:numel(sc)
        if sc(j) <= nSC_show
            gridImg(sc(j), sym(j)) = 2;
        end
    end
    
    subplot(1, 4, p);
    imagesc(0:nSym-1, 0:nSC_show-1, gridImg);
    colormap(gca, [0.2 0.2 0.2; 0.3 0.6 0.9; 1 0.2 0.2]);
    set(gca, 'YDir', 'normal', 'XTick', 0:13, 'YTick', 0:11);
    xlabel('OFDM Symbol'); ylabel('Subcarrier');
    title(sprintf('%s\n%s', patternLabels{p}, dmrsCfg.OverheadInfo.Description), ...
        'Interpreter', 'none');
    grid on;
end
sgtitle('DMRS Patterns in 1 PRB (Blue=Data, Red=DMRS, Dark=Empty)');
saveas(gcf, fullfile(resultsDir, 'plotS2_1_resource_grid.png'));
fprintf('Resource grid visualization saved.\n\n');

%% ============================================================
%% S2-A: Speed Sweep (DS = 100 ns)
%% ============================================================
fprintf('========================================\n');
fprintf('S2-A: Speed Sweep (DS=100ns, CDL-C)\n');
fprintf('========================================\n');

speeds = [3, 30, 120, 500];  % km/h
s2a = struct();

for si = 1:numel(speeds)
    speed = speeds(si);
    fprintf('\n=== Speed = %d km/h ===\n', speed);
    
    for p = 1:numel(patterns)
        simCfg = evm_pdsch_lls('NFrames', NFrames, 'SNRdB', SNRRange, ...
            'Modulation', '64QAM', 'TargetCodeRate', 0.65, ...
            'EnableHARQ', false, 'FixedTBS', true, ...
            'DelayProfile', 'CDL-C', 'DelaySpread', 100e-9, ...
            'UESpeed_kmh', speed);
        dmrsCfg = dmrs_config('PDSCH', 'Pattern', patterns{p});
        fprintf('  %s: ', patterns{p});
        s2a.(fname(sprintf('v%d', speed), patterns{p})) = ...
            run_pdsch_lls(simCfg, dmrsCfg, 'Verbose', true);
    end
end

%% ============================================================
%% S2-B: Delay Spread Sweep (speed = 30 km/h)
%% ============================================================
fprintf('\n========================================\n');
fprintf('S2-B: Delay Spread Sweep (30km/h, CDL-C)\n');
fprintf('========================================\n');

delaySpreads = [30e-9, 100e-9, 300e-9, 1000e-9];
dsLabels = {'30ns', '100ns', '300ns', '1000ns'};
s2b = struct();

for di = 1:numel(delaySpreads)
    ds = delaySpreads(di);
    fprintf('\n=== DS = %s ===\n', dsLabels{di});
    
    for p = 1:numel(patterns)
        simCfg = evm_pdsch_lls('NFrames', NFrames, 'SNRdB', SNRRange, ...
            'Modulation', '64QAM', 'TargetCodeRate', 0.65, ...
            'EnableHARQ', false, 'FixedTBS', true, ...
            'DelayProfile', 'CDL-C', 'DelaySpread', ds, ...
            'UESpeed_kmh', 30);
        dmrsCfg = dmrs_config('PDSCH', 'Pattern', patterns{p});
        fprintf('  %s: ', patterns{p});
        s2b.(fname(sprintf('ds%s', dsLabels{di}), patterns{p})) = ...
            run_pdsch_lls(simCfg, dmrsCfg, 'Verbose', true);
    end
end

%% ============================================================
%% S2-C: Corner Cases
%% ============================================================
fprintf('\n========================================\n');
fprintf('S2-C: Corner Cases\n');
fprintf('========================================\n');

cornerCases = {
    3,   30e-9,  'easy_3kmh_30ns',  'Easy: 3 km/h, 30 ns';
    500, 300e-9, 'hard_500kmh_300ns', 'Hard: 500 km/h, 300 ns';
};
s2c = struct();

for ci = 1:size(cornerCases, 1)
    speed = cornerCases{ci, 1};
    ds = cornerCases{ci, 2};
    label = cornerCases{ci, 3};
    fprintf('\n=== %s ===\n', cornerCases{ci, 4});
    
    for p = 1:numel(patterns)
        simCfg = evm_pdsch_lls('NFrames', NFrames, 'SNRdB', SNRRange, ...
            'Modulation', '64QAM', 'TargetCodeRate', 0.65, ...
            'EnableHARQ', false, 'FixedTBS', true, ...
            'DelayProfile', 'CDL-C', 'DelaySpread', ds, ...
            'UESpeed_kmh', speed);
        dmrsCfg = dmrs_config('PDSCH', 'Pattern', patterns{p});
        fprintf('  %s: ', patterns{p});
        s2c.(fname(label, patterns{p})) = ...
            run_pdsch_lls(simCfg, dmrsCfg, 'Verbose', true);
    end
end

%% ============================================================
%% PLOTS
%% ============================================================
fprintf('\n========================================\n');
fprintf('GENERATING PLOTS\n');
fprintf('========================================\n');

%% --- Plot S2-2: Speed Sweep BLER ---
figure('Position', [50 50 1400 900]);
for si = 1:numel(speeds)
    subplot(2, 2, si); hold on; grid on;
    for p = 1:numel(patterns)
        r = s2a.(fname(sprintf('v%d', speeds(si)), patterns{p}));
        semilogy(r.SNRdB, max(r.BLER, 1e-4), ...
            [colors{p} '-' markers{p}], 'LineWidth', 1.5, 'MarkerSize', 4);
    end
    xlabel('SNR (dB)'); ylabel('BLER'); ylim([1e-4 1]);
    doppler = round(speeds(si)/3.6 * 4e9/3e8, 1);
    title(sprintf('%d km/h (f_D = %.0f Hz)', speeds(si), doppler));
    legend(patternLabels, 'Location', 'southwest', 'FontSize', 7);
end
sgtitle('Speed Sweep — BLER (64QAM r=0.65, CDL-C, DS=100ns, HARQ OFF, Fixed TBS)');
saveas(gcf, fullfile(resultsDir, 'plotS2_2_speed_BLER.png'));

%% --- Plot S2-3: Speed Sweep MSE ---
figure('Position', [50 50 1400 900]);
for si = 1:numel(speeds)
    subplot(2, 2, si); hold on; grid on;
    for p = 1:numel(patterns)
        r = s2a.(fname(sprintf('v%d', speeds(si)), patterns{p}));
        semilogy(r.SNRdB, max(r.MSE_channelEst, 1e-8), ...
            [colors{p} '-' markers{p}], 'LineWidth', 1.5, 'MarkerSize', 4);
    end
    xlabel('SNR (dB)'); ylabel('CE MSE');
    doppler = round(speeds(si)/3.6 * 4e9/3e8, 1);
    title(sprintf('%d km/h (f_D = %.0f Hz)', speeds(si), doppler));
    legend(patternLabels, 'Location', 'northeast', 'FontSize', 7);
end
sgtitle('Speed Sweep — CE MSE (64QAM, CDL-C, DS=100ns)');
saveas(gcf, fullfile(resultsDir, 'plotS2_3_speed_MSE.png'));

%% --- Plot S2-4: Delay Spread Sweep BLER ---
figure('Position', [50 50 1400 900]);
for di = 1:numel(delaySpreads)
    subplot(2, 2, di); hold on; grid on;
    for p = 1:numel(patterns)
        r = s2b.(fname(sprintf('ds%s', dsLabels{di}), patterns{p}));
        semilogy(r.SNRdB, max(r.BLER, 1e-4), ...
            [colors{p} '-' markers{p}], 'LineWidth', 1.5, 'MarkerSize', 4);
    end
    xlabel('SNR (dB)'); ylabel('BLER'); ylim([1e-4 1]);
    title(sprintf('DS = %s', dsLabels{di}));
    legend(patternLabels, 'Location', 'southwest', 'FontSize', 7);
end
sgtitle('Delay Spread Sweep — BLER (64QAM r=0.65, CDL-C, 30 km/h, HARQ OFF, Fixed TBS)');
saveas(gcf, fullfile(resultsDir, 'plotS2_4_ds_BLER.png'));

%% --- Plot S2-5: Delay Spread Sweep MSE ---
figure('Position', [50 50 1400 900]);
for di = 1:numel(delaySpreads)
    subplot(2, 2, di); hold on; grid on;
    for p = 1:numel(patterns)
        r = s2b.(fname(sprintf('ds%s', dsLabels{di}), patterns{p}));
        semilogy(r.SNRdB, max(r.MSE_channelEst, 1e-8), ...
            [colors{p} '-' markers{p}], 'LineWidth', 1.5, 'MarkerSize', 4);
    end
    xlabel('SNR (dB)'); ylabel('CE MSE');
    title(sprintf('DS = %s', dsLabels{di}));
    legend(patternLabels, 'Location', 'northeast', 'FontSize', 7);
end
sgtitle('Delay Spread Sweep — CE MSE (64QAM, CDL-C, 30 km/h)');
saveas(gcf, fullfile(resultsDir, 'plotS2_5_ds_MSE.png'));

%% --- Plot S2-6: Corner Cases ---
figure('Position', [50 50 1200 500]);
for ci = 1:size(cornerCases, 1)
    label = cornerCases{ci, 3};
    subplot(1, 2, ci); hold on; grid on;
    for p = 1:numel(patterns)
        r = s2c.(fname(label, patterns{p}));
        semilogy(r.SNRdB, max(r.BLER, 1e-4), ...
            [colors{p} '-' markers{p}], 'LineWidth', 1.5, 'MarkerSize', 4);
    end
    xlabel('SNR (dB)'); ylabel('BLER'); ylim([1e-4 1]);
    title(cornerCases{ci, 4});
    legend(patternLabels, 'Location', 'southwest', 'FontSize', 7);
end
sgtitle('Corner Cases — BLER (64QAM r=0.65, CDL-C, HARQ OFF, Fixed TBS)');
saveas(gcf, fullfile(resultsDir, 'plotS2_6_corners_BLER.png'));

%% --- Plot S2-7: Summary Bar Charts — MSE at SNR=10 dB ---
figure('Position', [50 50 1400 500]);

% Speed sweep MSE at 10 dB
subplot(1, 2, 1);
mseData = zeros(numel(speeds), numel(patterns));
for si = 1:numel(speeds)
    for p = 1:numel(patterns)
        r = s2a.(fname(sprintf('v%d', speeds(si)), patterns{p}));
        idx = find(abs(r.SNRdB - 10) < 1, 1);
        if ~isempty(idx)
            mseData(si, p) = r.MSE_channelEst(idx);
        end
    end
end
bar(mseData);
set(gca, 'XTickLabel', arrayfun(@(s) sprintf('%d km/h', s), speeds, 'UniformOutput', false));
legend(patternLabels, 'Location', 'northwest', 'FontSize', 7);
ylabel('CE MSE at SNR=10 dB'); title('MSE vs UE Speed');
grid on;

% Delay spread sweep MSE at 10 dB
subplot(1, 2, 2);
mseData2 = zeros(numel(delaySpreads), numel(patterns));
for di = 1:numel(delaySpreads)
    for p = 1:numel(patterns)
        r = s2b.(fname(sprintf('ds%s', dsLabels{di}), patterns{p}));
        idx = find(abs(r.SNRdB - 10) < 1, 1);
        if ~isempty(idx)
            mseData2(di, p) = r.MSE_channelEst(idx);
        end
    end
end
bar(mseData2);
set(gca, 'XTickLabel', dsLabels);
legend(patternLabels, 'Location', 'northwest', 'FontSize', 7);
ylabel('CE MSE at SNR=10 dB'); title('MSE vs Delay Spread');
grid on;

sgtitle('Summary: CE MSE Sensitivity to Speed and Delay Spread');
saveas(gcf, fullfile(resultsDir, 'plotS2_7_summary_bars.png'));

%% --- Plot S2-8: MSE per pattern across speeds (one subplot per pattern) ---
figure('Position', [50 50 1400 900]);
for p = 1:numel(patterns)
    subplot(2, 2, p); hold on; grid on;
    speedColors = {'c', 'b', 'r', 'm'};
    for si = 1:numel(speeds)
        r = s2a.(fname(sprintf('v%d', speeds(si)), patterns{p}));
        semilogy(r.SNRdB, max(r.MSE_channelEst, 1e-8), ...
            [speedColors{si} '-' markers{si}], 'LineWidth', 1.5, 'MarkerSize', 4);
    end
    xlabel('SNR (dB)'); ylabel('CE MSE');
    title(patternLabels{p});
    legend(arrayfun(@(s) sprintf('%d km/h', s), speeds, 'UniformOutput', false), ...
        'Location', 'northeast', 'FontSize', 7);
end
sgtitle('MSE Sensitivity to Speed — Per Pattern');
saveas(gcf, fullfile(resultsDir, 'plotS2_8_speed_per_pattern.png'));

%% --- Plot S2-9: MSE per pattern across delay spreads ---
figure('Position', [50 50 1400 900]);
for p = 1:numel(patterns)
    subplot(2, 2, p); hold on; grid on;
    dsColors = {'c', 'b', 'r', 'm'};
    for di = 1:numel(delaySpreads)
        r = s2b.(fname(sprintf('ds%s', dsLabels{di}), patterns{p}));
        semilogy(r.SNRdB, max(r.MSE_channelEst, 1e-8), ...
            [dsColors{di} '-' markers{di}], 'LineWidth', 1.5, 'MarkerSize', 4);
    end
    xlabel('SNR (dB)'); ylabel('CE MSE');
    title(patternLabels{p});
    legend(dsLabels, 'Location', 'northeast', 'FontSize', 7);
end
sgtitle('MSE Sensitivity to Delay Spread — Per Pattern');
saveas(gcf, fullfile(resultsDir, 'plotS2_9_ds_per_pattern.png'));

%% ============================================================
%% SUMMARY TABLES
%% ============================================================
fprintf('\n========================================\n');
fprintf('SET 2 SUMMARY TABLES\n');
fprintf('========================================\n');

% Table S2-1: MSE at SNR=10 dB across speeds
fprintf('\n--- Table S2-1: CE MSE at SNR=10 dB vs Speed ---\n');
fprintf('%20s |', 'Pattern');
for si = 1:numel(speeds); fprintf(' %10d km/h', speeds(si)); end
fprintf('\n%s\n', repmat('-', 1, 65));
for p = 1:numel(patterns)
    fprintf('%20s |', patternLabels{p});
    for si = 1:numel(speeds)
        r = s2a.(fname(sprintf('v%d', speeds(si)), patterns{p}));
        idx = find(abs(r.SNRdB - 10) < 1, 1);
        if ~isempty(idx)
            fprintf(' %12.2e', r.MSE_channelEst(idx));
        end
    end
    fprintf('\n');
end

% Table S2-2: MSE at SNR=10 dB across delay spreads
fprintf('\n--- Table S2-2: CE MSE at SNR=10 dB vs Delay Spread ---\n');
fprintf('%20s |', 'Pattern');
for di = 1:numel(dsLabels); fprintf(' %12s', dsLabels{di}); end
fprintf('\n%s\n', repmat('-', 1, 70));
for p = 1:numel(patterns)
    fprintf('%20s |', patternLabels{p});
    for di = 1:numel(delaySpreads)
        r = s2b.(fname(sprintf('ds%s', dsLabels{di}), patterns{p}));
        idx = find(abs(r.SNRdB - 10) < 1, 1);
        if ~isempty(idx)
            fprintf(' %12.2e', r.MSE_channelEst(idx));
        end
    end
    fprintf('\n');
end

% Table S2-3: SNR at 10% BLER across speeds
fprintf('\n--- Table S2-3: SNR (dB) at 10%% BLER vs Speed ---\n');
fprintf('%20s |', 'Pattern');
for si = 1:numel(speeds); fprintf(' %10d km/h', speeds(si)); end
fprintf('\n%s\n', repmat('-', 1, 65));
for p = 1:numel(patterns)
    fprintf('%20s |', patternLabels{p});
    for si = 1:numel(speeds)
        r = s2a.(fname(sprintf('v%d', speeds(si)), patterns{p}));
        snr10 = find_snr_at_bler(r.SNRdB, r.BLER, 0.10);
        fprintf(' %11.1f ', snr10);
    end
    fprintf('\n');
end

% Table S2-4: SNR at 10% BLER across delay spreads
fprintf('\n--- Table S2-4: SNR (dB) at 10%% BLER vs Delay Spread ---\n');
fprintf('%20s |', 'Pattern');
for di = 1:numel(dsLabels); fprintf(' %12s', dsLabels{di}); end
fprintf('\n%s\n', repmat('-', 1, 70));
for p = 1:numel(patterns)
    fprintf('%20s |', patternLabels{p});
    for di = 1:numel(delaySpreads)
        r = s2b.(fname(sprintf('ds%s', dsLabels{di}), patterns{p}));
        snr10 = find_snr_at_bler(r.SNRdB, r.BLER, 0.10);
        fprintf(' %11.1f ', snr10);
    end
    fprintf('\n');
end

%% ===== Save =====
save(fullfile(resultsDir, 'set2_experiments.mat'), ...
    's2a', 's2b', 's2c', 'patterns', 'patternLabels', ...
    'speeds', 'delaySpreads', 'dsLabels', 'SNRRange', 'NFrames');
fprintf('\n\nAll Set 2 results saved to %s\n', resultsDir);
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
