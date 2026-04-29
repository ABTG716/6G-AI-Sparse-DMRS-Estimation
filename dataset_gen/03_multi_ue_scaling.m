%% generate_dataset_300UE.m
% Research-grade dataset generator
% 4x1 MIMO, random precoder per slot, full channel tensor stored
% 300 independent UEs

clc; clear;

%% ---------------- Simulation Parameters ----------------
numUE = 300;
SNRdB = 10;                 % global SNR for AWGN (you can randomize later)

frames = 20;
slotsPerFrame = 20;
totalNoSlots = frames * slotsPerFrame;   % 400 by default

rng("default");

%% ---------------- Carrier ----------------
carrier = nrCarrierConfig;
carrier.SubcarrierSpacing = 30;
carrier.NSizeGrid = 8;
carrier.NStartGrid = 0;
carrier.CyclicPrefix = "Normal";

numSC  = carrier.NSizeGrid * 12;
numSym = carrier.SymbolsPerSlot;

%% ---------------- PDSCH (base) ----------------
basePdsch = nrPDSCHConfig;
basePdsch.Modulation = "QPSK";
basePdsch.NumLayers = 1;
basePdsch.PRBSet = 0:7;
basePdsch.SymbolAllocation = [0 14];
basePdsch.DMRS.DMRSTypeAPosition = 2;
basePdsch.DMRS.DMRSLength = 1;
basePdsch.DMRS.DMRSAdditionalPosition = 1;
basePdsch.DMRS.DMRSConfigurationType = 1;
basePdsch.DMRS.NumCDMGroupsWithoutData = 2;

%% ---------------- LDPC / DLSCH ----------------
codeRate = 340/1024;

encodeDLSCH = nrDLSCH;
encodeDLSCH.MultipleHARQProcesses = false;
encodeDLSCH.TargetCodeRate = codeRate;

decodeDLSCH = nrDLSCHDecoder;
decodeDLSCH.MultipleHARQProcesses = false;
decodeDLSCH.TargetCodeRate = codeRate;
decodeDLSCH.LDPCDecodingAlgorithm = "Normalized min-sum";
decodeDLSCH.MaximumLDPCIterationCount = 30;

%% ---------------- MIMO / Channel ----------------
nTxAnts = 4;
nRxAnts = 1;

channel = nrCDLChannel;
channel.DelayProfile = "CDL-A";
channel.DelaySpread = 300e-9;
fc = 4e9;
v_kmph = 5;
v = v_kmph * 1000/3600;
c = 3e8;
fd = (v/c) * fc;
channel.MaximumDopplerShift = fd;

channel.TransmitAntennaArray.Size = [nTxAnts 1 1 1 1];
channel.ReceiveAntennaArray.Size  = [nRxAnts 1 1 1 1];
ofdmInfo = nrOFDMInfo(carrier);
channel.SampleRate = ofdmInfo.SampleRate;
channel.ChannelResponseOutput = 'ofdm-response';
%% ---------------- Preallocate datasets (big tensors) ----------------
% Warning: large memory usage. Change numUE/totalNoSlots to reduce memory.
inputDataset  = zeros(numSC, numSym, 2, totalNoSlots, numUE);        % real/imag
targetDataset = zeros(numSC, numSym, nTxAnts, 2, totalNoSlots, numUE); % full channel
txDataset     = zeros(numSC, numSym, 2, totalNoSlots, numUE);        % tx layer
precoderDataset = zeros(nTxAnts, totalNoSlots, numUE) + 1i*zeros(nTxAnts, totalNoSlots, numUE);

blockErrorsPerUE = zeros(numUE,1);

%% ---------------- Main UE loop ----------------
for ue = 1:numUE
    fprintf("Starting UE %d / %d\n", ue, numUE);
    release(channel);
    % Reset channel with different seed per UE for independence
    channel.Seed = randi([0 1e7]);
    reset(channel);

    % We'll create per-slot grids and metadata
    pdschIndicesCell = cell(totalNoSlots,1);
    pdschInfoCell    = cell(totalNoSlots,1);
    dmrsIndicesCell  = cell(totalNoSlots,1);
    dmrsSymbolsCell  = cell(totalNoSlots,1);
    trBlkSizesCell   = cell(totalNoSlots,1);
    pdschGridSlots   = cell(totalNoSlots,1);

    % Build per-slot TX data and place into bigGrid
    bigGrid = zeros(numSC, numSym * totalNoSlots, nTxAnts);

    for nSlot = 0:totalNoSlots-1
        carrier.NSlot = nSlot;
        slotIdx = nSlot + 1;
        slotSymStart = nSlot * numSym + 1;
        slotSymEnd   = (nSlot+1) * numSym;

        pdsch = basePdsch;

        % Indices & info
        [pdschIndices,pdschInfo] = nrPDSCHIndices(carrier,pdsch);
        pdschInfoCell{slotIdx} = pdschInfo;
        pdschIndicesCell{slotIdx} = pdschIndices;

        % TBS & transport block
        trBlkSizes = nrTBS(pdsch.Modulation,pdsch.NumLayers,...
            numel(pdsch.PRBSet),pdschInfo.NREPerPRB,codeRate,0);
        trBlkSizesCell{slotIdx} = trBlkSizes;

        % Set random transport block(s)
        for cwIdx = 1:pdsch.NumCodewords
            trBlk = randi([0 1],trBlkSizes(cwIdx),1);
            setTransportBlock(encodeDLSCH,trBlk,cwIdx-1);
        end
        rv = 0;
        codedTrBlock = encodeDLSCH(pdsch.Modulation,pdsch.NumLayers,pdschInfo.G,rv);

        % PDSCH modulation (per-layer symbols)
        pdschSymbols = nrPDSCH(carrier,pdsch,codedTrBlock);   % Symbols per layer

        % ------------------- RANDOM PRECODER (research-grade) -------------------
        w = (randn(nTxAnts,1) + 1i*randn(nTxAnts,1));
        w = w / norm(w);                 % unit-norm beam (Tx vector)
        precodingWeights = w.';          % 1 x nTxAnts
        precoderDataset(:,slotIdx,ue) = w;  % store for THIS UE & slot

        % Apply precoding (layer -> antenna)
        pdschSymbolsPrecoded = pdschSymbols * precodingWeights;  % Nsym x nTxAnts

        % DMRS for this slot
        dmrsSymbols = nrPDSCHDMRS(carrier,pdsch);
        dmrsIndices = nrPDSCHDMRSIndices(carrier,pdsch);
        dmrsSymbolsCell{slotIdx} = dmrsSymbols;
        dmrsIndicesCell{slotIdx} = dmrsIndices;

        % Make pdschGrid and insert PDSCH + DMRS (antenna domain)
        pdschGrid = nrResourceGrid(carrier, nTxAnts);
        [~,pdschAntIndices] = nrExtractResources(pdschIndices,pdschGrid);
        pdschGrid(pdschAntIndices) = pdschSymbolsPrecoded;

        for p = 1:size(dmrsSymbols,2)
            [~,dmrsAntIndices] = nrExtractResources(dmrsIndices(:,p),pdschGrid);
            pdschGrid(dmrsAntIndices) = pdschGrid(dmrsAntIndices) + dmrsSymbols(:,p)*precodingWeights(p,:);
        end

        pdschGridSlots{slotIdx} = pdschGrid;

        % Place into bigGrid columns corresponding to this slot
        bigGrid(:, slotSymStart:slotSymEnd, :) = pdschGrid;
    end

    % One-time OFDM modulation for the whole multi-slot grid
    carrier.NSlot = 0;
    [txWaveform, waveformInfo] = nrOFDMModulate(carrier, bigGrid);

    % pad for channel max delay
    chInfo = info(channel);
    txWaveform = [txWaveform; zeros(chInfo.MaximumChannelDelay, size(txWaveform,2))];

    % Channel call (continuous)
    [rxWaveform, ofdmChannelResponse] = channel(txWaveform, carrier);
    timingOffset = 0;   % CDL does not return timingOffset in this mode

    % AWGN (single add)
    [noise, nVar] = generateAWGN(SNRdB, txWaveform, nRxAnts);
    rxWaveform = rxWaveform + noise;

    % Trim initial timing offset if present
    if exist('timingOffset','var') && ~isempty(timingOffset)
        rxWaveform = rxWaveform(1+timingOffset:end,:);
    end

    % OFDM demodulate full received waveform -> full rxGrid
    carrier.NSlot = 0;
    rxGridFull = nrOFDMDemodulate(carrier, rxWaveform);   % SC x (Sym*slots) x Rx

    % ---------------- Per-slot RX processing & dataset store ----------------
    totalBlockErrors = 0;
    for nSlot = 0:totalNoSlots-1
        slotIdx = nSlot + 1;
        slotSymStart = nSlot * numSym + 1;
        slotSymEnd   = (nSlot+1) * numSym;

        pdsch = basePdsch;

        % slice received and true channel responses for this slot
        rxGrid = rxGridFull(:, slotSymStart:slotSymEnd, :);              % SC x sym x Rx
        ofdmChSlot = ofdmChannelResponse(:, slotSymStart:slotSymEnd, :); % SC x sym x Tx

        % ---------------- Store full 4x1 channel tensor (target)
        for tx = 1:nTxAnts
            targetDataset(:,:,tx,1,slotIdx,ue) = real(ofdmChSlot(:,:,tx));
            targetDataset(:,:,tx,2,slotIdx,ue) = imag(ofdmChSlot(:,:,tx));
        end

        % ---------------- Store transmitted layer (reference)
        pdschGrid = pdschGridSlots{slotIdx};
        txLayer = squeeze(pdschGrid(:,:,1));    % layer 1
        txDataset(:,:,1,slotIdx,ue) = real(txLayer);
        txDataset(:,:,2,slotIdx,ue) = imag(txLayer);

        % ---------------- Store received grid (input)
        rxLayer = squeeze(rxGrid(:,:,1));      % SC x sym (single RX)
        inputDataset(:,:,1,slotIdx,ue) = real(rxLayer);
        inputDataset(:,:,2,slotIdx,ue) = imag(rxLayer);

        % ---------------- Retrieve precoder used during TX for this UE & slot
        w = precoderDataset(:,slotIdx,ue);

        % ---------------- LS Channel Estimation using DMRS ----------------
        estChGridAnts = zeros(numSC, numSym, nTxAnts);
        dmrsMask = false(numSC, numSym);

        pdschGrid = pdschGridSlots{slotIdx};
        rxGridSlot = rxGrid;

        for p = 1:size(dmrsSymbolsCell{slotIdx},2)
            [txDmrs, txAntIdx] = nrExtractResources(dmrsIndicesCell{slotIdx}(:,p), pdschGrid);
            [rxDmrs, ~] = nrExtractResources(dmrsIndicesCell{slotIdx}(:,p), rxGridSlot);

            Ndmrs = size(txDmrs,1);
            for i = 1:Ndmrs
                [scIdx, symIdx, ~] = ind2sub(size(pdschGrid), txAntIdx(i));
                for tx = 1:nTxAnts
                    x = txDmrs(i,tx);
                    y = rxDmrs(i,1);
                    if abs(x) > 1e-12
                        estChGridAnts(scIdx, symIdx, tx) = y / x;
                    end
                end
                dmrsMask(scIdx, symIdx) = true;
            end
        end

        % ------------- Interpolation over time-frequency grid -------------
        [knownSC, knownSYM] = find(dmrsMask);
        if ~isempty(knownSC)
            for tx = 1:nTxAnts
                vals = zeros(length(knownSC),1);
                for k = 1:length(knownSC)
                    vals(k) = estChGridAnts(knownSC(k), knownSYM(k), tx);
                end
                F = scatteredInterpolant(double(knownSC), double(knownSYM), vals, 'linear', 'nearest');
                for sc = 1:numSC
                    for sym = 1:numSym
                        if ~dmrsMask(sc,sym)
                            estChGridAnts(sc,sym,tx) = F(sc,sym);
                        end
                    end
                end
            end
        else
            estChGridAnts = ofdmChSlot;  % fallback
        end

        noiseEst = nVar * waveformInfo.Nfft;

        % ---------------- Compute effective channel H_eff = H * w (1-layer)
        estChGridLayers = zeros(numSC, numSym, 1);
        for tx = 1:nTxAnts
            estChGridLayers(:,:,1) = estChGridLayers(:,:,1) + estChGridAnts(:,:,tx) * w(tx);
        end

        % ---------------- Equalization & Decoding ----------------
        pdschIndices = pdschIndicesCell{slotIdx};

        rxLayerGrid = reshape(rxLayer, numSC, numSym, 1);

        [pdschRx,pdschHest] = nrExtractResources(pdschIndices, rxLayerGrid, estChGridLayers);
        [pdschEq,csi] = nrEqualizeMMSE(pdschRx, pdschHest, noiseEst);

        [dlschLLRs,rxSymbols] = nrPDSCHDecode(carrier, pdsch, pdschEq, noiseEst);

        csi = nrLayerDemap(csi);
        for cwIdx = 1:pdsch.NumCodewords
            Qm = length(dlschLLRs{cwIdx})/length(rxSymbols{cwIdx});
            csi{cwIdx} = repmat(csi{cwIdx}.',Qm,1);
            dlschLLRs{cwIdx} = dlschLLRs{cwIdx} .* csi{cwIdx}(:);
        end

        reset(decodeDLSCH);
        decodeDLSCH.TransportBlockLength = trBlkSizesCell{slotIdx};
        [~,blkerr] = decodeDLSCH(dlschLLRs, pdsch.Modulation, pdsch.NumLayers, 0);

        blockError = any(blkerr);
        totalBlockErrors = totalBlockErrors + blockError;
        disp("Slot "+nSlot+" Block Error = "+blockError);
    end

    % Save per-UE BLER
    bler = totalBlockErrors / totalNoSlots;
    blockErrorsPerUE(ue) = bler;
    fprintf("UE %d BLER = %.4f\n", ue, bler);

    % Optional: save intermediate results to avoid memory blowup (uncomment)
    % save(sprintf('dataset_partial_ue_%03d.mat',ue),'inputDataset','targetDataset','txDataset','precoderDataset','blockErrorsPerUE','-v7.3','-nocompression');
end

%% ---------------- Save full dataset ----------------
outFile = 'TF_y_x_H_dataset_continuous_LS_300UE.mat';
save(outFile, 'inputDataset', 'targetDataset', 'txDataset', 'precoderDataset', 'blockErrorsPerUE', 'SNRdB', '-v7.3');
fprintf("Saved dataset to %s\n", outFile);

%% ---------------- Helper functions ----------------
function [noise,nVar] = generateAWGN(SNRdB, txWaveform, nRxAnts)
    % Compute actual TX waveform power (per complex sample)
    sigPow = mean(abs(txWaveform(:)).^2);
    SNR = 10^(SNRdB/10);
    nVar = sigPow / SNR;
    noise = sqrt(nVar/2) * (randn(size(txWaveform)) + 1i*randn(size(txWaveform)));
end