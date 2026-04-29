%% run_set3_experiments.m
% Set 3: Power normalization REVERTED. Diagnostic first, then sweeps.
%
% Phase 1: Quick diagnostic (10 frames) to verify MSE decreases with SNR
% Phase 2: Speed sweep + DS sweep (50 frames, SNR -5:5:30)

clearvars; close all; clc;
addpath(genpath(pwd));
addpath('C:\Users\5g_lab\Documents\MATLAB\Examples\R2025b\pre6g\LinkLevelSimulationfor6GExample');

patterns = {'nr_baseline', 'sparse_fd', 'sparse_td', 'sparse_fd_td'};
patternLabels = {'NR baseline (12 RE)', 'Sparse FD (8 RE)', 'Sparse TD (6 RE)', 'Sparse FD+TD (4 RE)'};
colors = {'b', 'r', 'g', 'm'};
markers = {'o', 's', 'd', '^'};

resultsDir = './results/set3';
if ~exist(resultsDir, 'dir'); mkdir(resultsDir); end
fname = @(prefix, pat) sprintf('e_%s_%s', prefix, pat);

%% PHASE 1: Diagnostic
fprintf('========================================\n');
fprintf('PHASE 1: Diagnostic (10 frames, 30km/h, DS=100ns)\n');
fprintf('========================================\n');

SNRDiag = -5:5:30;
for p = 1:numel(patterns)
    simCfg = evm_pdsch_lls('NFrames', 10, 'SNRdB', SNRDiag, ...
        'Modulation', '64QAM', 'TargetCodeRate', 0.65, ...
        'EnableHARQ', false, 'FixedTBS', true, ...
        'DelayProfile', 'CDL-C', 'DelaySpread', 100e-9, 'UESpeed_kmh', 30);
    dmrsCfg = dmrs_config('PDSCH', 'Pattern', patterns{p});
    fprintf('\n--- %s ---\n', patterns{p});
    r = run_pdsch_lls(simCfg, dmrsCfg, 'Verbose', true);
    fprintf('  MSE: '); fprintf('%.2e ', r.MSE_channelEst); fprintf('\n');
end
fprintf('\n--- PHASE 1 DONE. Check MSE decreases with SNR. ---\n\n');

%% PHASE 2: Full sweeps
NFrames = 50; SNRRange = -5:5:30;
speeds = [3 30 120 500];
delaySpreads = [30e-9 100e-9 300e-9 1000e-9];
dsLabels = {'30ns','100ns','300ns','1000ns'};

fprintf('========================================\n');
fprintf('PHASE 2: Speed Sweep\n');
fprintf('========================================\n');
s3a = struct();
for si = 1:numel(speeds)
    fprintf('\n=== %d km/h ===\n', speeds(si));
    for p = 1:numel(patterns)
        simCfg = evm_pdsch_lls('NFrames', NFrames, 'SNRdB', SNRRange, ...
            'Modulation', '64QAM', 'TargetCodeRate', 0.65, ...
            'EnableHARQ', false, 'FixedTBS', true, ...
            'DelayProfile', 'CDL-C', 'DelaySpread', 100e-9, 'UESpeed_kmh', speeds(si));
        dmrsCfg = dmrs_config('PDSCH', 'Pattern', patterns{p});
        fprintf('  %s: ', patterns{p});
        s3a.(fname(sprintf('v%d',speeds(si)), patterns{p})) = run_pdsch_lls(simCfg, dmrsCfg, 'Verbose', true);
    end
end

fprintf('\n========================================\n');
fprintf('PHASE 2: Delay Spread Sweep\n');
fprintf('========================================\n');
s3b = struct();
for di = 1:numel(delaySpreads)
    fprintf('\n=== DS=%s ===\n', dsLabels{di});
    for p = 1:numel(patterns)
        simCfg = evm_pdsch_lls('NFrames', NFrames, 'SNRdB', SNRRange, ...
            'Modulation', '64QAM', 'TargetCodeRate', 0.65, ...
            'EnableHARQ', false, 'FixedTBS', true, ...
            'DelayProfile', 'CDL-C', 'DelaySpread', delaySpreads(di), 'UESpeed_kmh', 30);
        dmrsCfg = dmrs_config('PDSCH', 'Pattern', patterns{p});
        fprintf('  %s: ', patterns{p});
        s3b.(fname(sprintf('ds%s',dsLabels{di}), patterns{p})) = run_pdsch_lls(simCfg, dmrsCfg, 'Verbose', true);
    end
end

%% PLOTS
figure('Position',[50 50 1400 900]);
for si=1:4; subplot(2,2,si); hold on; grid on;
    for p=1:4; r=s3a.(fname(sprintf('v%d',speeds(si)),patterns{p}));
        semilogy(r.SNRdB,max(r.BLER,1e-4),[colors{p} '-' markers{p}],'LineWidth',1.5,'MarkerSize',6); end
    xlabel('SNR (dB)'); ylabel('BLER'); ylim([1e-4 1]);
    title(sprintf('%d km/h',speeds(si))); legend(patternLabels,'Location','southwest','FontSize',7);
end; sgtitle('Set3: Speed Sweep BLER'); saveas(gcf,fullfile(resultsDir,'plotS3_1_speed_BLER.png'));

figure('Position',[50 50 1400 900]);
for si=1:4; subplot(2,2,si); hold on; grid on;
    for p=1:4; r=s3a.(fname(sprintf('v%d',speeds(si)),patterns{p}));
        semilogy(r.SNRdB,max(r.MSE_channelEst,1e-8),[colors{p} '-' markers{p}],'LineWidth',1.5,'MarkerSize',6); end
    xlabel('SNR (dB)'); ylabel('CE MSE');
    title(sprintf('%d km/h',speeds(si))); legend(patternLabels,'Location','northeast','FontSize',7);
end; sgtitle('Set3: Speed Sweep MSE'); saveas(gcf,fullfile(resultsDir,'plotS3_2_speed_MSE.png'));

figure('Position',[50 50 1400 900]);
for di=1:4; subplot(2,2,di); hold on; grid on;
    for p=1:4; r=s3b.(fname(sprintf('ds%s',dsLabels{di}),patterns{p}));
        semilogy(r.SNRdB,max(r.BLER,1e-4),[colors{p} '-' markers{p}],'LineWidth',1.5,'MarkerSize',6); end
    xlabel('SNR (dB)'); ylabel('BLER'); ylim([1e-4 1]);
    title(sprintf('DS=%s',dsLabels{di})); legend(patternLabels,'Location','southwest','FontSize',7);
end; sgtitle('Set3: DS Sweep BLER'); saveas(gcf,fullfile(resultsDir,'plotS3_3_ds_BLER.png'));

figure('Position',[50 50 1400 900]);
for di=1:4; subplot(2,2,di); hold on; grid on;
    for p=1:4; r=s3b.(fname(sprintf('ds%s',dsLabels{di}),patterns{p}));
        semilogy(r.SNRdB,max(r.MSE_channelEst,1e-8),[colors{p} '-' markers{p}],'LineWidth',1.5,'MarkerSize',6); end
    xlabel('SNR (dB)'); ylabel('CE MSE');
    title(sprintf('DS=%s',dsLabels{di})); legend(patternLabels,'Location','northeast','FontSize',7);
end; sgtitle('Set3: DS Sweep MSE'); saveas(gcf,fullfile(resultsDir,'plotS3_4_ds_MSE.png'));

%% TABLES
fprintf('\n--- SNR at 10%% BLER vs Speed ---\n');
fprintf('%25s |','Pattern'); for si=1:4; fprintf(' %8d km/h',speeds(si)); end; fprintf('\n');
for p=1:4; fprintf('%25s |',patternLabels{p});
    for si=1:4; r=s3a.(fname(sprintf('v%d',speeds(si)),patterns{p}));
        fprintf(' %10.1f',find_snr_at_bler(r.SNRdB,r.BLER,0.10)); end; fprintf('\n'); end

fprintf('\n--- SNR at 10%% BLER vs DS ---\n');
fprintf('%25s |','Pattern'); for di=1:4; fprintf(' %10s',dsLabels{di}); end; fprintf('\n');
for p=1:4; fprintf('%25s |',patternLabels{p});
    for di=1:4; r=s3b.(fname(sprintf('ds%s',dsLabels{di}),patterns{p}));
        fprintf(' %10.1f',find_snr_at_bler(r.SNRdB,r.BLER,0.10)); end; fprintf('\n'); end

save(fullfile(resultsDir,'set3_experiments.mat'),'s3a','s3b','patterns','patternLabels','speeds','delaySpreads','dsLabels','SNRRange','NFrames');
fprintf('\nDONE.\n');

function snr = find_snr_at_bler(v,b,t)
    i=find(b<=t,1,'first'); if isempty(i); snr=NaN; elseif i==1; snr=v(1);
    else; snr=v(i-1)+(v(i)-v(i-1))*(b(i-1)-t)/(b(i-1)-b(i)); end
end
