function results = run_pdsch_lls(simCfg, dmrsCfg, varargin)
%RUN_PDSCH_LLS 6G PDSCH link-level simulation with configurable DMRS.
%
%   results = RUN_PDSCH_LLS(simCfg, dmrsCfg)
%   results = RUN_PDSCH_LLS(simCfg, dmrsCfg, 'GenerateDataset', true)
%
%   Processing chain matches the MathWorks "6G Link-Level Simulation"
%   example exactly: pre6GCarrierConfig, pre6GPDSCHConfig, hPDSCHTransmit,
%   hPDSCHReceive, hpre6GDLSCH, hpre6GDLSCHDecoder, HARQEntity, etc.
%
%   Our additions on top:
%     - Configurable DMRS patterns via dmrs_config()
%     - Channel estimation MSE measurement
%     - AI dataset generation (rxGrid, rxDMRS, perfectH, estimatedH)

    p = inputParser;
    addParameter(p, 'GenerateDataset', false);
    addParameter(p, 'DatasetPath', './dataset');
    addParameter(p, 'MaxSamplesPerSNR', 1000);
    addParameter(p, 'Verbose', true);
    parse(p, varargin{:});
    opts = p.Results;

    %% ===== Build simParameters struct (MathWorks-compatible) =====
    simParameters = struct();
    simParameters.NFrames = simCfg.NFrames;
    simParameters.SNRdB = simCfg.SNRdB;
    simParameters.PerfectChannelEstimator = simCfg.PerfectChannelEstimation;
    simParameters.DisplaySimulationInformation = false;
    simParameters.DisplayDiagnostics = false;
    simParameters.enableParallelism = false;

    % Carrier — must be pre6GCarrierConfig
    simParameters.Carrier = pre6GCarrierConfig;
    simParameters.Carrier.NSizeGrid = simCfg.NSizeGrid;
    simParameters.Carrier.SubcarrierSpacing = simCfg.SubcarrierSpacing;

    % PDSCH — must be pre6GPDSCHConfig
    simParameters.PDSCH = pre6GPDSCHConfig;
    simParameters.PDSCH.PRBSet = 0:simParameters.Carrier.NSizeGrid-1;
    simParameters.PDSCH.SymbolAllocation = [0, simParameters.Carrier.SymbolsPerSlot];
    simParameters.PDSCH.NumLayers = simCfg.NumLayers;
    if simParameters.PDSCH.NumCodewords > 1
        simParameters.PDSCH.Modulation = {simCfg.Modulation, simCfg.Modulation};
    else
        simParameters.PDSCH.Modulation = simCfg.Modulation;
    end

    % Apply DMRS config
    simParameters.PDSCH.DMRS.DMRSConfigurationType = dmrsCfg.DMRSConfigurationType;
    simParameters.PDSCH.DMRS.DMRSLength = dmrsCfg.DMRSLength;
    simParameters.PDSCH.DMRS.DMRSAdditionalPosition = dmrsCfg.DMRSAdditionalPosition;
    simParameters.PDSCH.DMRS.DMRSTypeAPosition = dmrsCfg.DMRSTypeAPosition;
    simParameters.PDSCH.DMRS.NumCDMGroupsWithoutData = dmrsCfg.NumCDMGroupsWithoutData;
    simParameters.PDSCH.DMRS.DMRSPortSet = dmrsCfg.DMRSPortSet;
    if ~isempty(dmrsCfg.NIDNSCID)
        simParameters.PDSCH.DMRS.NIDNSCID = dmrsCfg.NIDNSCID;
    end
    simParameters.PDSCH.DMRS.NSCID = dmrsCfg.NSCID;
    if ~isempty(dmrsCfg.CustomSymbolSet)
        simParameters.PDSCH.DMRS.CustomSymbolSet = dmrsCfg.CustomSymbolSet;
    end

    % PT-RS
    simParameters.PDSCH.EnablePTRS = dmrsCfg.EnablePTRS;

    % Fixed TBS mode: reserve freed DMRS REs so data RE count matches
    % the NR baseline, ensuring identical TBS/G/code rate across patterns.
    if simCfg.FixedTBS && ~strcmp(dmrsCfg.PatternName, 'nr_baseline')
        reservedRE = compute_reserved_re_for_fixed_tbs( ...
            simParameters.Carrier, dmrsCfg);
        simParameters.PDSCH.ReservedRE = reservedRE;
    end

    % PDSCHExtension
    simParameters.PDSCHExtension = struct();
    if simParameters.PDSCH.NumCodewords > 1
        simParameters.PDSCHExtension.TargetCodeRate = ...
            [simCfg.TargetCodeRate simCfg.TargetCodeRate];
    else
        simParameters.PDSCHExtension.TargetCodeRate = simCfg.TargetCodeRate;
    end
    simParameters.PDSCHExtension.PRGBundleSize = simCfg.PRGBundleSize;
    simParameters.PDSCHExtension.NHARQProcesses = 16;
    simParameters.PDSCHExtension.EnableHARQ = simCfg.EnableHARQ;
    simParameters.PDSCHExtension.LDPCDecodingAlgorithm = 'Normalized min-sum';
    simParameters.PDSCHExtension.MaximumLDPCIterationCount = 20;

    % Antennas
    simParameters.NTxAnts = simCfg.NTxAnts;
    simParameters.NRxAnts = simCfg.NRxAnts;

    % Channel model
    simParameters.DelayProfile = simCfg.DelayProfile;
    simParameters.DelaySpread = simCfg.DelaySpread;
    simParameters.MaximumDopplerShift = simCfg.MaxDopplerShift;

    %% ===== Validate =====
    numlayers = simParameters.PDSCH.NumLayers;
    if numlayers > min(simParameters.NTxAnts, simParameters.NRxAnts)
        error('NumLayers (%d) must be <= min(NTxAnts,NRxAnts) = %d', ...
            numlayers, min(simParameters.NTxAnts, simParameters.NRxAnts));
    end

    %% ===== Setup (matches MathWorks pdschLink function) =====
    carrier = simParameters.Carrier;
    pdsch = simParameters.PDSCH;
    pdschextra = simParameters.PDSCHExtension;
    numSNR = numel(simParameters.SNRdB);
    totalSlots = simParameters.NFrames * carrier.SlotsPerFrame;

    % DL-SCH encoder/decoder — hpre6G versions
    encodeDLSCH = hpre6GDLSCH;
    encodeDLSCH.MultipleHARQProcesses = true;
    encodeDLSCH.TargetCodeRate = pdschextra.TargetCodeRate;

    decodeDLSCH = hpre6GDLSCHDecoder;
    decodeDLSCH.MultipleHARQProcesses = true;
    decodeDLSCH.TargetCodeRate = pdschextra.TargetCodeRate;
    decodeDLSCH.LDPCDecodingAlgorithm = pdschextra.LDPCDecodingAlgorithm;
    decodeDLSCH.MaximumLDPCIterationCount = pdschextra.MaximumLDPCIterationCount;

    % OFDM info
    ofdmInfo = hpre6GOFDMInfo(carrier);

    % CDL channel
    channel = nrCDLChannel;
    channel = hArrayGeometry(channel, simParameters.NTxAnts, simParameters.NRxAnts);
    nTxAnts = prod(channel.TransmitAntennaArray.Size);
    nRxAnts = prod(channel.ReceiveAntennaArray.Size);
    channel.DelayProfile = simParameters.DelayProfile;
    channel.DelaySpread = simParameters.DelaySpread;
    channel.MaximumDopplerShift = simParameters.MaximumDopplerShift;
    channel.SampleRate = ofdmInfo.SampleRate;
    channel.Seed = randi([0 2^32-1]);

    chInfo = info(channel);
    maxChDelay = chInfo.MaximumChannelDelay;

    % RV sequence
    if pdschextra.EnableHARQ
        rvSeq = [0 2 3 1];
    else
        rvSeq = 0;
    end

    % Results storage
    results = struct();
    results.SNRdB = simParameters.SNRdB;
    results.BLER = zeros(1, numSNR);
    results.InitialBLER = zeros(1, numSNR);
    results.Throughput = zeros(1, numSNR);
    results.ThroughputMbps = zeros(1, numSNR);
    results.MSE_channelEst = zeros(1, numSNR);
    results.NumRetransmissions = zeros(1, numSNR);
    results.NumInitialTx = zeros(1, numSNR);
    results.RetxSuccessRate = NaN(1, numSNR);
    results.SimConfig = simCfg;
    results.DMRSConfig = dmrsCfg;

    if opts.GenerateDataset
        datasetDir = fullfile(opts.DatasetPath, dmrsCfg.PatternName);
        if ~exist(datasetDir, 'dir'); mkdir(datasetDir); end
    end

    % Compute baseline TBS for FixedTBS mode
    % This is the TBS that the NR baseline DMRS pattern would produce.
    % When FixedTBS is enabled, all patterns are forced to this value.
    fixedTBSValue = [];
    if simCfg.FixedTBS
        pdsch_bl = pre6GPDSCHConfig;
        pdsch_bl.PRBSet = 0:carrier.NSizeGrid-1;
        pdsch_bl.SymbolAllocation = [0, carrier.SymbolsPerSlot];
        pdsch_bl.NumLayers = simCfg.NumLayers;
        pdsch_bl.Modulation = simCfg.Modulation;
        pdsch_bl.DMRS.DMRSConfigurationType = 1;
        pdsch_bl.DMRS.DMRSLength = 1;
        pdsch_bl.DMRS.DMRSAdditionalPosition = 1;
        pdsch_bl.DMRS.DMRSTypeAPosition = 2;
        pdsch_bl.DMRS.NumCDMGroupsWithoutData = 2;
        fixedTBSValue = hpre6GTBS(pdsch_bl, pdschextra.TargetCodeRate);
        fprintf('FixedTBS mode: baseline TBS = %d\n', fixedTBSValue);
    end

    % Log DMRS pattern info for traceability
    fprintf('DMRS pattern: %s, Overhead: %s\n', dmrsCfg.PatternName, dmrsCfg.OverheadInfo.Description);

    %% ===== SNR Loop =====
    for snrIdx = 1:numSNR
        SNRdB_val = simParameters.SNRdB(snrIdx);
        SNR = 10^(SNRdB_val / 10);
        N0 = 1 / sqrt(double(ofdmInfo.Nfft) * SNR * nRxAnts);
        nPowerPerRE = N0^2 * ofdmInfo.Nfft;

        reset(channel);
        reset(decodeDLSCH);

        harqSequence = 0:pdschextra.NHARQProcesses - 1;
        harqEntity = HARQEntity(harqSequence, rvSeq, pdsch.NumCodewords);

        % Initial precoder via perfect CE (same as MathWorks example)
        estChannelGrid = getInitialChannelEstimate( ...
            carrier, nTxAnts, channel);
        wtx = hSVDPrecoders(carrier, pdsch, estChannelGrid, ...
            pdschextra.PRGBundleSize);

        % Counters
        totalBits = 0;
        correctBits = 0;
        mseAccum = 0;
        mseCount = 0;
        sampleCount = 0;
        datasetSamples = {};
        
        % HARQ statistics
        harqStats = struct();
        harqStats.initialTx = 0;       % Count of initial transmissions
        harqStats.initialTxErr = 0;    % Count of initial tx failures
        harqStats.retx = 0;            % Count of retransmissions
        harqStats.retxErr = 0;         % Count of retransmission failures
        harqStats.finalBlocks = 0;     % Total blocks (final outcome)
        harqStats.finalErrors = 0;     % Final errors (after all HARQ attempts)

        if opts.Verbose
            fprintf('SNR = %+6.1f dB: ', SNRdB_val);
        end

        for nSlot = 0:totalSlots - 1
            carrier.NSlot = nSlot;

            % --- TBS ---
            [pdschIndices, pdschIndicesInfo] = hpre6GPDSCHIndices(carrier, pdsch);
            trBlkSizes = hpre6GTBS(pdsch, pdschextra.TargetCodeRate);
            
            % Override TBS with baseline value in FixedTBS mode
            if ~isempty(fixedTBSValue)
                trBlkSizes = fixedTBSValue;
            end

            % --- DL-SCH encode ---
            % HARQ: generate new data or retransmit
            for cwIdx = 1:pdsch.NumCodewords
                if harqEntity.NewData(cwIdx)
                    trBlk = randi([0 1], trBlkSizes(cwIdx), 1);
                    setTransportBlock(encodeDLSCH, trBlk, ...
                        cwIdx - 1, harqEntity.HARQProcessID);
                end
            end
            codedTrBlocks = encodeDLSCH(pdschIndicesInfo.Qm, ...
                pdsch.NumLayers, pdschIndicesInfo.G, ...
                harqEntity.RedundancyVersion, harqEntity.HARQProcessID);

            % --- Transmit: PDSCH mod + precode + OFDM ---
            % hPDSCHTransmit internally calls hpre6GPDSCH, hpre6GPDSCHDMRS,
            % hpre6GPDSCHDMRSIndices, hpre6GPDSCHPTRS, hpre6GPDSCHPrecode,
            % hpre6GOFDMModulate
            [txWaveform, pdschSymbols] = hPDSCHTransmit( ...
                carrier, pdsch, codedTrBlocks, wtx);

            % NOTE: No transmit power normalization. The MathWorks SNR
            % formula N0=1/sqrt(Nfft*SNR*NRxAnts) assumes unit-power per
            % active RE, which is naturally satisfied by the QAM/DMRS
            % modulators. Different patterns have slightly different
            % total transmit power due to different numbers of zero REs
            % (DMRS/CDM-reserved), but the per-active-RE SNR is correct.
            % Normalizing the waveform would break the MSE computation
            % because perfectH does not include the normalization factor.

            % --- Channel ---
            txWaveform = [txWaveform; zeros(maxChDelay, size(txWaveform, 2))]; %#ok<AGROW>
            [rxWaveform, pathGains, sampleTimes] = channel(txWaveform);

            % --- Noise ---
            noise = N0 * randn(size(rxWaveform), "like", rxWaveform);
            rxWaveform = rxWaveform + noise;

            % --- Receive: sync + OFDM demod + CE + equalize + decode ---
            % hPDSCHReceive internally handles perfect/practical CE,
            % MMSE equalization, CPE compensation, PDSCH decode, CSI scaling
            pathFilters = getPathFilters(channel);
            perfEstConfig = struct();
            perfEstConfig.PathGains = pathGains;
            perfEstConfig.PathFilters = pathFilters;
            perfEstConfig.SampleTimes = sampleTimes;
            perfEstConfig.NoiseEstimate = nPowerPerRE;
            perfEstConfig.PerfectChannelEstimator = ...
                simParameters.PerfectChannelEstimator;

            % Save current precoder (used for this slot's Tx) before
            % hPDSCHReceive updates it for the next slot
            wtx_thisSlot = wtx;

            [dlschLLRs, wtx, pdschEq] = hPDSCHReceive( ...
                carrier, pdsch, pdschextra, rxWaveform, wtx_thisSlot, perfEstConfig);

            % --- MSE and dataset generation ---
            % These require separate calls to get perfect/estimated channel
            offset = nrPerfectTimingEstimate(pathGains, pathFilters);
            perfectH = hpre6GPerfectChannelEstimate( ...
                carrier, pathGains, pathFilters, offset, sampleTimes);

            if ~simParameters.PerfectChannelEstimator
                rxGridDS = hpre6GOFDMDemodulate(carrier, ...
                    rxWaveform(1 + offset:end, :));
                dmrsSymDS = hpre6GPDSCHDMRS(carrier, pdsch);
                dmrsIndDS = hpre6GPDSCHDMRSIndices(carrier, pdsch);
                [estH, ~] = hpre6GChannelEstimate(carrier, rxGridDS, ...
                    dmrsIndDS, dmrsSymDS, ...
                    'CDMLengths', pdsch.DMRS.CDMLengths);

                % MSE: Compare practical vs perfect CE in the port domain.
                %
                % perfectH is K×L×Rx×Tx (antenna domain).
                % estH is K×L×Rx×P (port domain, after precoding).
                %
                % Method (same as hPDSCHReceive perfect CE path):
                % 1. Extract perfectH at DMRS RE positions
                % 2. Apply precoder to get port-domain perfect CE
                % 3. Compare against practical estH at same positions
                [~, perfectH_dmrs, ~, dmrsHestIndices] = ...
                    nrExtractResources(dmrsIndDS, rxGridDS, perfectH);
                perfectH_port = hpre6GPDSCHPrecode(carrier, ...
                    perfectH_dmrs, dmrsHestIndices, ...
                    permute(wtx_thisSlot, [2 1 3]));

                % Extract practical estimate at same DMRS positions
                [~, estH_dmrs] = nrExtractResources(dmrsIndDS, ...
                    rxGridDS, estH);

                % Match dimensions and compute MSE
                minDim3 = min(size(perfectH_port, 3), size(estH_dmrs, 3));
                pH = perfectH_port(:, 1:minDim3);
                eH = estH_dmrs(:, 1:minDim3);
                validIdx = ~isnan(pH(:)) & ~isnan(eH(:));
                if any(validIdx)
                    mseVal = mean(abs(pH(validIdx) - eH(validIdx)).^2);
                    mseAccum = mseAccum + mseVal;
                    mseCount = mseCount + 1;
                end
            end

            % Dataset generation
            if opts.GenerateDataset && sampleCount < opts.MaxSamplesPerSNR
                sample = struct();
                if ~exist('rxGridDS', 'var')
                    rxGridDS = hpre6GOFDMDemodulate(carrier, ...
                        rxWaveform(1 + offset:end, :));
                    dmrsSymDS = hpre6GPDSCHDMRS(carrier, pdsch);
                    dmrsIndDS = hpre6GPDSCHDMRSIndices(carrier, pdsch);
                    [estH, noiseEstDS] = hpre6GChannelEstimate( ...
                        carrier, rxGridDS, dmrsIndDS, dmrsSymDS, ...
                        'CDMLengths', pdsch.DMRS.CDMLengths);
                end
                sample.rxGrid = rxGridDS;
                sample.rxDMRS = rxGridDS(dmrsIndDS);
                sample.perfectH = perfectH;
                sample.estimatedH = estH;
                sample.dmrsIndices = dmrsIndDS;
                sample.dmrsSymbols = dmrsSymDS;
                sample.snrDB = SNRdB_val;
                sample.slotIdx = nSlot;
                sampleCount = sampleCount + 1;
                datasetSamples{sampleCount} = sample; %#ok<AGROW>
            end

            % Clear per-slot temporaries for next iteration
            clear rxGridDS dmrsSymDS dmrsIndDS estH noiseEstDS;

            % --- DL-SCH decode ---
            for cwIdx = 1:pdsch.NumCodewords
                if harqEntity.NewData(cwIdx) && harqEntity.SequenceTimeout(cwIdx)
                    resetSoftBuffer(decodeDLSCH, cwIdx - 1, ...
                        harqEntity.HARQProcessID);
                end
            end
            decodeDLSCH.TransportBlockLength = trBlkSizes;
            [~, blkerr] = decodeDLSCH(dlschLLRs, pdschIndicesInfo.Qm, ...
                pdsch.NumLayers, harqEntity.RedundancyVersion, ...
                harqEntity.HARQProcessID);

            % HARQ statistics: track initial vs retransmission outcomes
            for cwIdx = 1:pdsch.NumCodewords
                if harqEntity.NewData(cwIdx)
                    % This is an initial transmission
                    harqStats.initialTx = harqStats.initialTx + 1;
                    if blkerr(cwIdx)
                        harqStats.initialTxErr = harqStats.initialTxErr + 1;
                    end
                else
                    % This is a retransmission
                    harqStats.retx = harqStats.retx + 1;
                    if blkerr(cwIdx)
                        harqStats.retxErr = harqStats.retxErr + 1;
                    end
                end
            end
            % Track final outcome (SequenceTimeout = failed after all RVs)
            % This is tracked after updateAndAdvance via the next NewData

            % Update HARQ
            updateAndAdvance(harqEntity, blkerr, trBlkSizes, ...
                pdschIndicesInfo.G);

            % Accumulate
            totalBits = totalBits + sum(trBlkSizes);
            correctBits = correctBits + sum(~blkerr .* trBlkSizes);
        end % slot loop

        % --- Store per-SNR results ---
        results.BLER(snrIdx) = 1 - (correctBits / totalBits);
        results.Throughput(snrIdx) = 100 * correctBits / totalBits;
        results.ThroughputMbps(snrIdx) = ...
            1e-6 * correctBits / (simParameters.NFrames * 10e-3);
        if mseCount > 0
            results.MSE_channelEst(snrIdx) = mseAccum / mseCount;
        end
        
        % HARQ statistics
        if harqStats.initialTx > 0
            results.InitialBLER(snrIdx) = harqStats.initialTxErr / harqStats.initialTx;
        else
            results.InitialBLER(snrIdx) = 0;
        end
        results.NumRetransmissions(snrIdx) = harqStats.retx;
        results.NumInitialTx(snrIdx) = harqStats.initialTx;
        if harqStats.retx > 0
            results.RetxSuccessRate(snrIdx) = 1 - (harqStats.retxErr / harqStats.retx);
        else
            results.RetxSuccessRate(snrIdx) = NaN;
        end

        if opts.Verbose
            fprintf('BLER=%.4f (init=%.4f), Tput=%.1f%%, MSE=%.2e, ReTx=%d/%d\n', ...
                results.BLER(snrIdx), results.InitialBLER(snrIdx), ...
                results.Throughput(snrIdx), results.MSE_channelEst(snrIdx), ...
                harqStats.retx, harqStats.initialTx);
        end

        % Save dataset
        if opts.GenerateDataset && sampleCount > 0
            snrLabel = sprintf('snr_%+03d', round(SNRdB_val));
            dsFile = fullfile(datasetDir, [snrLabel '.mat']);
            save(dsFile, 'datasetSamples', 'simCfg', 'dmrsCfg', '-v7.3');
            if opts.Verbose
                fprintf('  Saved %d samples -> %s\n', sampleCount, dsFile);
            end
        end
    end % SNR loop

    results.DMRSOverhead = dmrsCfg.OverheadInfo;
    results.Timestamp = datetime('now');
end

%% ===== Local functions (matching MathWorks example exactly) =====

function estChannelGrid = getInitialChannelEstimate(carrier, nTxAnts, propchannel)
    % Get channel estimate before first transmission for initial precoding.
    % Copied from the MathWorks 6G LLS example.
    ofdmInfo = hpre6GOFDMInfo(carrier);
    chInfo = info(propchannel);
    maxChDelay = chInfo.MaximumChannelDelay;

    tmpWaveform = zeros( ...
        (ofdmInfo.SampleRate/1000/carrier.SlotsPerSubframe) + maxChDelay, ...
        nTxAnts, "single");

    [~, pathGains, sampleTimes] = propchannel(tmpWaveform);
    pathFilters = getPathFilters(propchannel);
    offset = nrPerfectTimingEstimate(pathGains, pathFilters);
    estChannelGrid = hpre6GPerfectChannelEstimate( ...
        carrier, pathGains, pathFilters, offset, sampleTimes);
end

function reservedRE = compute_reserved_re_for_fixed_tbs(carrier, dmrsCfg)
    % Compute ReservedRE indices so that a sparse DMRS pattern has the
    % same number of data REs as the NR baseline pattern.
    %
    % Method: 
    %   1. Build NR baseline PDSCH config → get its DMRS RE indices
    %   2. Build sparse PDSCH config → get its DMRS RE indices
    %   3. The difference (baseline DMRS REs NOT in sparse DMRS REs)
    %      are REs that the sparse pattern freed up for data
    %   4. Mark those freed REs as ReservedRE → PDSCH won't map data there
    %   5. Result: same data RE count → same TBS/G/code rate
    
    % Build NR baseline PDSCH config
    pdsch_baseline = pre6GPDSCHConfig;
    pdsch_baseline.PRBSet = 0:carrier.NSizeGrid-1;
    pdsch_baseline.SymbolAllocation = [0, carrier.SymbolsPerSlot];
    pdsch_baseline.NumLayers = 1;  % Will be overridden if needed
    % NR baseline DMRS: Type 1, single-symbol, 1 additional position
    pdsch_baseline.DMRS.DMRSConfigurationType = 1;
    pdsch_baseline.DMRS.DMRSLength = 1;
    pdsch_baseline.DMRS.DMRSAdditionalPosition = 1;
    pdsch_baseline.DMRS.DMRSTypeAPosition = 2;
    pdsch_baseline.DMRS.NumCDMGroupsWithoutData = 2;
    
    % Build sparse PDSCH config (using the actual dmrsCfg)
    pdsch_sparse = pre6GPDSCHConfig;
    pdsch_sparse.PRBSet = 0:carrier.NSizeGrid-1;
    pdsch_sparse.SymbolAllocation = [0, carrier.SymbolsPerSlot];
    pdsch_sparse.NumLayers = 1;
    pdsch_sparse.DMRS.DMRSConfigurationType = dmrsCfg.DMRSConfigurationType;
    pdsch_sparse.DMRS.DMRSLength = dmrsCfg.DMRSLength;
    pdsch_sparse.DMRS.DMRSAdditionalPosition = dmrsCfg.DMRSAdditionalPosition;
    pdsch_sparse.DMRS.DMRSTypeAPosition = dmrsCfg.DMRSTypeAPosition;
    pdsch_sparse.DMRS.NumCDMGroupsWithoutData = dmrsCfg.NumCDMGroupsWithoutData;
    
    % Get DMRS indices for both configs (1-based linear, carrier-oriented)
    % These include both DMRS REs and the REs reserved due to 
    % NumCDMGroupsWithoutData (REs in CDM groups that can't carry data)
    dmrsInd_baseline = hpre6GPDSCHDMRSIndices(carrier, pdsch_baseline);
    dmrsInd_sparse = hpre6GPDSCHDMRSIndices(carrier, pdsch_sparse);
    
    % Also get data indices to find the difference in data RE allocation
    dataInd_baseline = hpre6GPDSCHIndices(carrier, pdsch_baseline);
    dataInd_sparse = hpre6GPDSCHIndices(carrier, pdsch_sparse);
    
    % Find data REs that exist in sparse but NOT in baseline
    % These are the "freed" REs that we need to reserve
    % Work with first port/layer only (indices are per-layer)
    dataRE_baseline = dataInd_baseline(:,1);
    dataRE_sparse = dataInd_sparse(:,1);
    
    freedREs = setdiff(dataRE_sparse, dataRE_baseline);
    
    % Convert from 1-based carrier-oriented to 0-based BWP-oriented
    % (ReservedRE uses 0-based indexing within the BWP)
    reservedRE = freedREs - 1;
    
    fprintf('  FixedTBS: reserving %d freed REs (baseline data REs: %d, sparse data REs: %d)\n', ...
        numel(reservedRE), numel(dataRE_baseline), numel(dataRE_sparse));
end
