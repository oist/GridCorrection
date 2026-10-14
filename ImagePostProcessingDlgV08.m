%IMAGEPOSTPROCESSINGDLGV08  Geometric distortion correction -- OLDER VERSION.
%
%   Measures and corrects geometric distortion in momentum microscope and
%   TEM images, using the shadow of a regular TEM grid as the reference.
%
%   Superseded, kept as a frozen snapshot of how the app worked at the time.
%   The current version is ImagePostProcessingDlgV11. See README.md.
%
classdef ImagePostProcessingDlgV08 < matlab.apps.AppBase

    % Properties that correspond to app components
    properties (Access = public)
        ImageCorrectionDialogUIFigure  matlab.ui.Figure

        % V5: the entire dashboard/setup UI (Home, Flatfield, Grid config,
        % Objective config) is a single HTML/CSS/JS single-page app hosted
        % in one uihtml component filling the figure, instead of native
        % uicontrols -- see BuildMainUIHTML/BuildViewModel/MainUIDataChanged.
        MainUI                         matlab.ui.control.HTML

        % V6: the interactive grid-point editor -- previously a separate
        % plain figure(1) window with an annotation/uicontrol sidebar --
        % now lives in this SAME figure instead. GridAxes is a drop-in
        % replacement for figure(1)'s image axes (drawpoint/ROIMoved/
        % ROIClicked all work identically on a uiaxes, confirmed live
        % before starting this rewrite); GridSidebarUI is a second uihtml
        % component replacing the old annotation-based legend/instructions
        % and uicontrol-based nav/action buttons, styled to match MainUI.
        % Only one of {MainUI} or {GridAxes,GridSidebarUI} is Visible at a
        % time -- see EnterGridEditorMode/ExitGridEditorMode.
        GridAxes                       matlab.ui.control.UIAxes
        GridSidebarUI                  matlab.ui.control.HTML

        % Diagnostic accessor: GridCompareFittingMethods stashes its
        % return value here too (in addition to returning it) so results
        % -- fitted positions/convergence per method, not just the
        % printed summary -- are reachable from outside for ad hoc
        % analysis/visualization without a dedicated UI for it.
        GridLastCompareResults = [];

        % Same rationale, for GridSeedPlaneLattice: cell{plane}, each a
        % struct array with one entry per attempt (predict from the
        % current trend -> light pass -> check quality -> probe if
        % needed), so the trend-tracing/bridging trajectory is reachable
        % for ad hoc analysis/visualization.
        GridLastSeedHistory = {};
    end


    properties (Access = private)
        % --- V5 shadow state for former dashboard/config uicontrols ---
        % (grid_SizeX/Y/Z, grid_PlaneStart/Averaging/Interval, and
        % image_OutputShiftX/Y already exist as private properties below
        % and serve this same role for their fields; these are the ones
        % that had no such shadow property because they were always read
        % straight from a live uicontrol.Value)
        ui_VerboseOutput = true;
        ui_OptimizeGrid = true;
        ui_ApplyFF = false;
        ui_ApplyGC = false;
        ui_ApplyDC = false;
        ui_TransformationMethod = '1';
        ui_Style = 'STV 0, All Points';

        % Enable/disable flags for the Grid setup page, formerly expressed
        % as uicontrol.Enable toggles inside GridSettingStatusChange
        ui_GridFieldsEnabled = true;
        ui_QuickSetupEnabled = false;
        ui_ApplyGCEnabled = false;
        grid_SizeX =10; %number of grid points in X direction
        grid_SizeY =10; %number of grid points in Y direction
        grid_SizeZ =8;  %number of grid planes
 
        grid_PlaneStart     =400;    %slide # for first grid plane
        grid_PlaneAveraging =10;      %number of slide to average to represent a plane
        grid_PlaneInterval  =50;     %number of slide between each plane

        img_SizeZ           %number of slide in the raw image 

        ImgBufReady = false;
        grid_PlaneImgBuf
        ref_Image

        % Per-Z sample-coordinate grids for the piecewise correction
        % methods, reused across the FILES of a batch run (the grid
        % depends only on Z and the grid geometry, never on image
        % content). Reset by GridBuildGCTransforms at the start of every
        % run, and capped -- see gc_SampleGridCacheMax.
        gc_SampleGridCache = struct('Xq',{{}}, 'Yq',{{}}, 'stored',0);
        % At a 378x378 output that's ~114MB of single-precision grids.
        % Caching stops (rather than evicting) once this many are held, so
        % a long stack can't thrash the cache or grow without bound -- the
        % reuse only exists across files anyway, so a stack with more
        % slides than this simply recomputes the rest.
        gc_SampleGridCacheMax = 100;

        grid_Position;       %positions of grid points (index(x,y), pos(x,y), z)
        grid_Info ={};       %other info about the grid points {x,y,z} 

        fig_GridHandle = {};  %grid points handle in fig object
        
        grid_Init_Position;
        fig_Grid_InitHandle = {};
        fig_Grid_InitHandleReady = false;

        grid_PlaneCurrent = 1
        grid_SettingStatus = 0;  %differnt level of ready...

        filename_GridRef = 'none';              %grid reference image 
        filename_Flatfield ='none';             %flatfield image 
        filename_CurrentSettings = 'none';      %master settings 
        filename_GeometricDistortion = 'none';  %geometric distortion setting 

        image_OutputShiftX=0
        image_OutputShiftY=0

        workingDirectory;                       %save working directory
        parentApp;
        rotationOn=true;                        %rotate the local fit offset back into image (x,y) frame;
                                                 %must be true whenever dx,dy (grid spacing vector) is not
                                                 %axis-aligned, which is normal for a rotated/distorted grid
        fitOneGrid=true;                        %fit one or three grid lines together
        fitRange=6;                             %maximum search area between grid points
        debug=0;                                %headless/scripted-test mode: suppresses every modal this
                                                 %app would otherwise block on (confirm-before-rerun, the
                                                 %save-on-close prompt, the flatfield/lens-distortion file
                                                 %pickers) and injects canned manual-seed points. MUST stay
                                                 %0 for normal use -- it shipped as 1, which silently
                                                 %disabled all of those for real users too (the same trap
                                                 %that once made Load Settings look broken; see
                                                 %LoadSettingsButtonPushed).
        debugPlot=false;                        %plot fit results; synced from ShowFittingFigureCheckBox,
                                                 %off by default since it redraws on every single-point
                                                 %fit during batch population. NOT gated on debug -- it is
                                                 %a normal user-facing toggle.

        grid_LatticeModel = {};                 %per-plane auto-detected (or manual) global lattice model:
                                                 %spacing/orientation/phase used to predict every crossing's
                                                 %position independently, instead of neighbor propagation
        grid_SurfaceModel = {};                 %per-plane robust global 2D polynomial surface fit (sfX,sfY)
        grid_AutoDetectEnabled = true;          %use automatic FFT-based lattice detection when possible
        grid_RefinementPasses = 2;              %number of predict->refine->smooth passes per plane
                                                 %(whether to optimize at all is controlled by the
                                                 %OptimizeGridCheckBox UI control, not a private property,
                                                 %matching the ApplyFFCheckBox/ApplyGCCheckBox convention)
        grid_PendingOriginConfirm = [];          %stashed (plane,latticeModel,anchorHandle,anchorPos)
                                                 %between ConfirmGridOriginAndRefine's setup and
                                                 %GridConfirmOriginClicked's finalize -- replaces the
                                                 %old uiwait(msgbox(...)) blocking-dialog flow, which
                                                 %could get hidden behind the main window while dragging

        % V6: GridSidebarUI state, pushed via BuildGridEditorViewModel.
        % ui_GridNav mirrors the old GridSetSidebarEnable-toggled
        % uicontrol.Enable states (one flag per nav/action button, keyed
        % the same way: 'first','prev','next','last','optimizePlane',
        % 'correctionTest','adjustOrigin','populateRest').
        ui_GridEditorMode = false;               %true while GridAxes/GridSidebarUI are the visible
                                                 %content of the shared figure instead of MainUI
        ui_GridSidebarMode = 'normal';            %'normal' or 'originConfirm' -- mirrors the old
                                                 %GridEnterOriginConfirmMode/GridExitOriginConfirmMode
                                                 %button-repurposing, done via view-model + JS instead
        ui_GridOriginConfirmInfo = '';            %spacing/rotation summary line shown only in
                                                 %'originConfirm' mode
        ui_GridNav = struct('first',false, 'prev',false, 'next',false, 'last',false, ...
            'optimizePlane',false, 'correctionTest',false, 'adjustOrigin',false, 'populateRest',false);
        ui_ViewEditorEnabled = false;             %enables a "View / Edit Grid" button on the Grid
                                                 %config page so the editor can be reopened without
                                                 %re-running Quick Setup's detection from scratch

        % State as of the last save/load/reset, for the save-on-close
        % prompt -- see GridSettingsFingerprint/GridHasUnsavedChanges.
        ui_SavedStateFingerprint = {};

        % One-time forced-navigation request for MainUI, e.g. so the grid
        % editor's Finish button lands on Home specifically instead of
        % whatever page was showing before (page switching is otherwise
        % pure client-side JS that MATLAB never needs to know about).
        % ui_MainUINavigateToken increments each time a fresh request is
        % made; the JS side only acts on a token it hasn't seen yet.
        ui_MainUINavigateToken = 0;
        ui_MainUINavigateTo = '';
    end
    
    methods (Access = private)
        
        function LoadReferenceImage(app)
            filename=app.filename_GridRef;
            file_info = imfinfo(filename);
            app.img_SizeZ = numel(file_info);

            Height=file_info.Height;
            Width=file_info.Width;

            rawImage=zeros(Height,Width,app.grid_PlaneAveraging);
            app.grid_PlaneImgBuf=zeros(Height,Width,app.grid_SizeZ);

            % V7: if a flatfield image is configured, apply it to every
            % plane BEFORE grid detection/fitting ever sees the data --
            % previously flatfield was only applied at final batch
            % correction time (CorrectImagesButtonPushed), so an
            % illumination gradient could get silently absorbed into
            % GridFitSmoothSurface's fitted distortion trend instead of
            % being removed as the flat-field artifact it actually is.
            % Same multiplicative-gain convention as the batch-correction
            % path (AvgInt./FFImage), computed once and reused for every
            % plane -- valid because gain factors out of the per-plane
            % sum: sum_k(raw_k .* gain) == gain .* sum_k(raw_k).
            [FFGain, ffOK] = GridLoadFlatfieldGainMap(app);

            fig=app.ImageCorrectionDialogUIFigure;
            title='Loading Grid Reference Image';
            dlg=uiprogressdlg(fig, 'Title', title, 'Cancelable','on');

            % A single native Tiff object, seeking directly between
            % frames via setDirectory, replaces repeated
            % imread(filename, idx) calls here -- imread reopens and
            % re-parses the file's whole IFD chain from the start on
            % every call, which turns reading a large stack frame-by-
            % frame into effectively O(n^2) work; Tiff opens the file
            % once and each setDirectory/read pair is a direct seek.
            tiffReader = Tiff(filename, 'r');
            cleanupTiffReader = onCleanup(@() close(tiffReader)); % closes even on error/cancel

            for index=1:app.grid_SizeZ
                msg=sprintf('Please wait');
                progress_bar=index/(app.grid_SizeZ);
                dlg.Value=progress_bar;
                dlg.Message=msg;

                for k=1:app.grid_PlaneAveraging
                    tiffReader.setDirectory(GridPlaneSlideNumber(app, index)+k);
                    rawImage(:,:,k) = tiffReader.read();
                end
                tempImage=sum(rawImage,3);
                tempImage=squeeze(tempImage);
                if ffOK
                    tempImage = tempImage .* FFGain;
                end
                app.grid_PlaneImgBuf(:,:,index)=tempImage;
                if dlg.CancelRequested
                    break
                end
            end
            close(dlg);

            app.ImgBufReady=true;
        end

        function [FFGain, ok] = GridLoadFlatfieldGainMap(app)
            % Loads and normalizes the configured flatfield image into a
            % multiplicative per-pixel gain map, using the exact same
            % convention as CorrectImagesButtonPushed's batch-correction
            % flatfield step (kept as an independent copy rather than a
            % shared call, so this new pre-detection path can't affect
            % that already-validated batch pipeline). ok=false (with
            % FFGain=[]) whenever no flatfield is configured or it fails
            % to load -- callers should just skip flatfield application
            % in that case, not treat it as a hard error.
            FFGain = [];
            ok = false;
            if strcmp(app.filename_Flatfield, 'none')
                return;
            end
            try
                FFImage = imread(app.filename_Flatfield, 1);
                FFImage = single(FFImage);
                FFImageSize = size(FFImage);
                rowRange = round(FFImageSize(1)*0.25):round(FFImageSize(1)*0.75);
                colRange = round(FFImageSize(2)*0.25):round(FFImageSize(2)*0.75);
                CropFFImage = FFImage(rowRange, colRange);
                AvgInt = sum(CropFFImage(:)) / numel(CropFFImage);
                FFGain = AvgInt ./ FFImage;
                FFGain(FFGain==Inf) = 0;
                ok = true;
            catch ME
                GridLog(app, 'Flatfield image could not be loaded/applied before grid detection: %s', ME.message);
            end
        end
        
        
        function GridPositionMoved(app, src)
            selected=str2double(src{1}.Tag);
            app.grid_Position(selected,:, app.grid_PlaneCurrent)=app.fig_GridHandle{selected}.handle.Position;
            app.grid_Info{selected, app.grid_PlaneCurrent}.status=1;            
%            app.grid_SettingStatus=true;
        end
        
        function GridInitPositionMoved(app, src)
            selected=str2double(src{1}.Tag);
            app.grid_Init_Position(selected,:)=app.fig_Grid_InitHandle{selected}.handle.Position;
        end

        function GridPositionClicked(app,src)
            uiresume();
            selected=str2double(src{1}.Tag);
            app.grid_Position(selected,:, app.grid_PlaneCurrent)=app.fig_GridHandle{selected}.handle.Position;
        end
        
        function DistortionCorrectionTest(app)

            ChangeRefImagePlane(app);

            [RA, worldPoints, squareSize]=GridTransformationInitialize(app, app.grid_PlaneCurrent);

            grid_Position_Current=app.grid_Position(:,:,app.grid_PlaneCurrent);
            transformationMethod=str2double(app.ui_TransformationMethod);

            % Per-point residual of THIS correction's own fit, in the same
            % raw-image coordinate space as grid_Position_Current -- filled
            % in below for whichever method actually runs. Using
            % transformPointsInverse (world/ideal -> raw) rather than
            % transformPointsForward works uniformly across every tform
            % class fitgeotrans can return: the plain polynomial transform
            % (methods 3/4) only implements the inverse direction, not
            % forward (confirmed: images.geotrans.PolynomialTransformation2D
            % has no transformPointsForward method at all).
            nTotal = app.grid_SizeX*app.grid_SizeY;
            afterResidual = zeros(nTotal,2);

            switch(transformationMethod)
                case 1
                    tform = fitgeotrans(grid_Position_Current,worldPoints,"affine");
                case 2
                    tform = fitgeotrans(grid_Position_Current,worldPoints,"projective");
                case 3
                    tform = fitgeotrans(grid_Position_Current,worldPoints,"polynomial", 3);
                case 4
                    tform = fitgeotrans(grid_Position_Current,worldPoints,"polynomial", 4);
            end

            if(transformationMethod<5)
                correctedImage=imwarp(app.ref_Image, tform, 'interp', 'cubic', 'Outputview', RA); %nearest, linear or cubic
                afterResidual = grid_Position_Current - tform.transformPointsInverse(worldPoints);
            else
                %code for piecewise correction
                %m,n position in mini maps; i,j positions in world maps

                %find output position in the large worldmap
%                firstWorldPoint=[grid_Position_Current(1,1)/RA.PixelExtentInWorldX grid_Position_Current(1,2)/RA.PixelExtentInWorldY];

                miniOutputPosition=zeros(9,2);
                miniGridPosition=zeros(9,2);

                mini_ImageSize=2*squareSize;
                RA_mini = imref2d([mini_ImageSize mini_ImageSize]);
    
                miniWorldPoints = generateCheckerboardPoints([4 4], squareSize);
                miniWorldPoints = flip(miniWorldPoints,2);  %exchange x and y axis in world points
                
                % ceil() (not floor()) + clamping i_current/j_current below
                % -- floor() alone silently drops the last grid column/row
                % whenever grid_SizeX/Y is even (e.g. this app's own
                % default, 10): 2*floor((N-1)/2)+1 can never reach an even
                % N, so correctedImage was allocated a full squareSize
                % short of the true output and that edge band was never
                % written. ceil() adds the needed extra block, and
                % clamping keeps that last block's far edge from
                % overshooting past the real last column/row (it just
                % overlaps the previous block a bit more instead).
                iL=ceil((app.grid_SizeX-1)/2);
                jL=ceil((app.grid_SizeY-1)/2);

                correctedImage=zeros((app.grid_SizeY-1)*squareSize, (app.grid_SizeX-1)*squareSize);

                for j=1:jL
                    for i=1:iL
                        i_current=min(1+(i-1)*2, app.grid_SizeX-2);
                        j_current=min(1+(j-1)*2, app.grid_SizeY-2);
                        idxWorldBlock=zeros(9,1);
                        for n=1:3
                            for m=1:3
                                index_mini=m+(n-1)*3;
                                index_world=i_current+m-1+(j_current+n-2)*app.grid_SizeX;
                                idxWorldBlock(index_mini)=index_world;
                                miniOutputPosition(index_mini,:)=worldPoints(index_world,:);
                                miniGridPosition(index_mini,:)=grid_Position_Current(index_world,:);
                            end
                        end

                        index=i+(j-1)*iL;
                        app.ref_Image=insertText(app.ref_Image, [miniGridPosition(1,1)+10 miniGridPosition(1,2)+10], index, "TextColor","white", "FontSize", 20, 'BoxOpacity',0);
                        app.ref_Image=app.ref_Image(:,:,1);

                        xOutput = [miniOutputPosition(1,2) miniOutputPosition(end,2)];
                        yOutput = [miniOutputPosition(1,1) miniOutputPosition(end,1)];

                        switch(transformationMethod)
                            case 5
                                tform = fitgeotrans(miniGridPosition,miniWorldPoints,"affine");
                            case 6
                                tform = fitgeotrans(miniGridPosition,miniWorldPoints,"projective");
                            case 7
                                tform = fitgeotrans(miniGridPosition,miniWorldPoints,"polynomial", 2);

                        end
                        % A point can belong to more than one overlapping
                        % block; whichever block is processed last "wins"
                        % for both the assembled image (already true below)
                        % and this residual, for consistency.
                        afterResidual(idxWorldBlock,:) = miniGridPosition - tform.transformPointsInverse(miniWorldPoints);

                        correctedminiImage=imwarp(app.ref_Image, tform, 'interp', 'cubic', 'Outputview', RA_mini); %nearest, linear or cubic
                        correctedImage((xOutput(1)+1):xOutput(2), (yOutput(1)+1):yOutput(2))=correctedminiImage;
                    end
                end
            end

            % "Before" residual: how far this plane's own RAW points sit
            % from the best possible perfect grid (a rigid, uniformly-
            % scaled, orthogonal 'nonreflectivesimilarity' fit), in the
            % same raw-image coordinate space as afterResidual above, so
            % the two are directly comparable arrow-for-arrow.
            gxIdx = zeros(nTotal,1);
            gyIdx = zeros(nTotal,1);
            for grid_y=1:app.grid_SizeY
                for grid_x=1:app.grid_SizeX
                    idx=(grid_y-1)*app.grid_SizeX+grid_x;
                    gxIdx(idx)=grid_x;
                    gyIdx(idx)=grid_y;
                end
            end
            idealTform = fitgeotrans([gxIdx gyIdx], grid_Position_Current, 'nonreflectivesimilarity');
            beforeResidual = grid_Position_Current - idealTform.transformPointsForward([gxIdx gyIdx]);

            % Same arrow scale for both vector maps -- auto-scaling each
            % independently would visually normalize away the very
            % improvement this comparison exists to show.
            maxMag = max([hypot(beforeResidual(:,1),beforeResidual(:,2)); hypot(afterResidual(:,1),afterResidual(:,2))]);
            targetLenCells = 0.4; % longest arrow (across BOTH maps) spans this many grid cells
            if maxMag > 0
                arrowScale = targetLenCells / maxMag;
            else
                arrowScale = 1;
            end

            modelNames = {'1: Affine','2: Projective','3: Polynomial (3rd order)','4: Polynomial (4th order)', ...
                '5: Piecewise Affine','6: Piecewise Projective','7: Piecewise Polynomial (2nd order)'};
            modelName = modelNames{transformationMethod};

            figHandle=figure(2);
            set(figHandle, 'NumberTitle', 'off', 'Name', sprintf('Grid Correction Test on Plane #%d -- Model %s', app.grid_PlaneCurrent, modelName));
            set(figHandle, 'Position', [100 100 1000 900]);
            clf(figHandle);
            sgtitle(figHandle, sprintf('Correction model in use: %s', modelName), 'FontWeight','bold');

            subplot(2,2,1);
            imshow(app.ref_Image, [0 3]);
            title('Before Correction');
            subplot(2,2,2);
            imshow(correctedImage, [0 3]);
            title('After Correction');

            subplot(2,2,3);
            GridPlotResidualVectors(app, gxIdx, gyIdx, beforeResidual, arrowScale, maxMag, ...
                'Before: raw points vs. best-fit ideal grid');
            subplot(2,2,4);
            GridPlotResidualVectors(app, gxIdx, gyIdx, afterResidual, arrowScale, maxMag, ...
                'After: this correction''s own fit residual');
        end

        function GridPlotResidualVectors(app, gxIdx, gyIdx, residualVec, arrowScale, refLen, titleStr)
            % Shared vector-map plotting for DistortionCorrectionTest's
            % before/after panels -- draws into the CURRENT axes (a
            % subplot) rather than creating its own figure, and takes an
            % already-decided arrowScale/refLen (the longest arrow across
            % BOTH panels) so before/after stay comparable.
            nX = app.grid_SizeX;
            nY = app.grid_SizeY;
            plot(gxIdx, gyIdx, 'k.', 'MarkerSize', 10);
            hold on;
            quiver(gxIdx, gyIdx, residualVec(:,1)*arrowScale, residualVec(:,2)*arrowScale, ...
                0, 'Color','r', 'LineWidth',1.2, 'MaxHeadSize',0.5);

            % Scale-reference arrow + label, drawn directly on the plot
            % rather than only stated in a caption elsewhere -- lets a
            % viewer compare any arrow's length against this one, known,
            % labeled magnitude at a glance. Same refLen (and therefore the
            % same on-screen length) is used in both the before and after
            % panel. Placed in a margin BELOW the grid -- the margin above
            % it is where the stats text box below goes, and the two
            % overlapped (the text box's white background was hiding the
            % arrow entirely) when both were up top.
            refX0 = 1; refY0 = nY+0.7;
            quiver(refX0, refY0, refLen*arrowScale, 0, 0, 'Color','k', 'LineWidth',1.5, 'MaxHeadSize',1.5);
            text(refX0, refY0+0.4, sprintf('= %.2f px', refLen), 'FontSize',8, 'HorizontalAlignment','left');

            hold off;
            axis image;
            set(gca, 'YDir', 'reverse');
            xlim([0.5 nX+0.5]); ylim([0.2 nY+1.4]);
            grid on;
            xlabel('Grid X index'); ylabel('Grid Y index');
            title(titleStr);

            % Per-panel summary statistics of the (unscaled, real-pixel)
            % residual magnitude, overlaid on the plot itself.
            mag = hypot(residualVec(:,1), residualVec(:,2));
            statsStr = sprintf('RMS=%.2fpx   mean=%.2fpx   max=%.2fpx', sqrt(mean(mag.^2)), mean(mag), max(mag));
            text(0.02, 0.98, statsStr, 'Units','normalized', 'VerticalAlignment','top', ...
                'BackgroundColor','white', 'FontSize',8, 'Margin',2);
        end

        function afterResidual = GridComputeMethodResidual(app, grid_Position_Current, worldPoints, squareSize, method)
            % Per-point residual of fitting the given transformation
            % method to this plane's own raw points -- how far short that
            % method's own parametric form (affine/projective/poly3/poly4/
            % piecewise-X) falls of exactly reproducing the ideal target,
            % WITHOUT ever warping the actual image or re-detecting
            % anything on a corrected image. This is deliberately just the
            % fitted transform's own fit quality: computing the new grid
            % point positions directly from the transform matrix already
            % shows how much the grid would improve, no need to actually
            % apply the correction to the image and refit. Same math as
            % DistortionCorrectionTest's own single-method residual
            % (transformPointsInverse rather than Forward, since
            % PolynomialTransformation2D -- methods 3/4 -- only implements
            % the inverse direction), extracted here so
            % GridCompareAllModels can run all 7 methods cheaply in one
            % click instead of needing 7 separate image-warp passes.
            nTotal = app.grid_SizeX*app.grid_SizeY;
            afterResidual = zeros(nTotal,2);

            if method <= 4
                switch method
                    case 1
                        tform = fitgeotrans(grid_Position_Current,worldPoints,"affine");
                    case 2
                        tform = fitgeotrans(grid_Position_Current,worldPoints,"projective");
                    case 3
                        tform = fitgeotrans(grid_Position_Current,worldPoints,"polynomial", 3);
                    case 4
                        tform = fitgeotrans(grid_Position_Current,worldPoints,"polynomial", 4);
                end
                afterResidual = grid_Position_Current - tform.transformPointsInverse(worldPoints);
            else
                miniWorldPoints = generateCheckerboardPoints([4 4], squareSize);
                miniWorldPoints = flip(miniWorldPoints,2);  %exchange x and y axis in world points

                % Same ceil()+clamping as CorrectImagesButtonPushed/
                % DistortionCorrectionTest's piecewise branch (even
                % grid_SizeX/Y coverage fix).
                iL=ceil((app.grid_SizeX-1)/2);
                jL=ceil((app.grid_SizeY-1)/2);
                miniGridPosition=zeros(9,2);

                for j=1:jL
                    for i=1:iL
                        i_current=min(1+(i-1)*2, app.grid_SizeX-2);
                        j_current=min(1+(j-1)*2, app.grid_SizeY-2);
                        idxWorldBlock=zeros(9,1);
                        for n=1:3
                            for m=1:3
                                index_mini=m+(n-1)*3;
                                index_world=i_current+m-1+(j_current+n-2)*app.grid_SizeX;
                                idxWorldBlock(index_mini)=index_world;
                                miniGridPosition(index_mini,:)=grid_Position_Current(index_world,:);
                            end
                        end
                        switch method
                            case 5
                                tform = fitgeotrans(miniGridPosition,miniWorldPoints,"affine");
                            case 6
                                tform = fitgeotrans(miniGridPosition,miniWorldPoints,"projective");
                            case 7
                                tform = fitgeotrans(miniGridPosition,miniWorldPoints,"polynomial", 2);
                        end
                        afterResidual(idxWorldBlock,:) = miniGridPosition - tform.transformPointsInverse(miniWorldPoints);
                    end
                end
            end
        end

        function GridCompareAllModels(app)
            % Compares all 7 correction models on this plane's ALREADY-
            % MEASURED points at once -- no image warping, no
            % re-detection, just each method's own fitted-transform
            % residual (GridComputeMethodResidual), which is fast enough
            % (a handful of small least-squares fits) to run all 7 in one
            % click. Shows an 8-panel vector map (before + one per method,
            % all sharing one arrow scale so they're directly comparable)
            % plus a summary bar chart for an at-a-glance ranking.
            if app.grid_SettingStatus < 3
                uialert(app.ImageCorrectionDialogUIFigure, ...
                    'Compare All Models needs at least one plane populated first.', 'Not Ready');
                return;
            end

            % GridTransformationInitialize needs app.ref_Image's SIZE --
            % after a Load Settings restore, ref_Image/grid_PlaneImgBuf are
            % empty (settings only persist grid data, not raw image
            % buffers) until something actually reads the TIFF, same as
            % GridBuildCorrectedPlaneImages' equivalent fix.
            ChangeRefImagePlane(app);

            [~, worldPoints, squareSize] = GridTransformationInitialize(app, app.grid_PlaneCurrent);
            grid_Position_Current = app.grid_Position(:,:,app.grid_PlaneCurrent);

            nTotal = app.grid_SizeX*app.grid_SizeY;
            gxIdx = zeros(nTotal,1);
            gyIdx = zeros(nTotal,1);
            for grid_y=1:app.grid_SizeY
                for grid_x=1:app.grid_SizeX
                    idx=(grid_y-1)*app.grid_SizeX+grid_x;
                    gxIdx(idx)=grid_x;
                    gyIdx(idx)=grid_y;
                end
            end
            idealTform = fitgeotrans([gxIdx gyIdx], grid_Position_Current, 'nonreflectivesimilarity');
            beforeResidual = grid_Position_Current - idealTform.transformPointsForward([gxIdx gyIdx]);

            methodNames = {'1: Affine','2: Projective','3: Poly-3','4: Poly-4', ...
                '5: Piecewise Affine','6: Piecewise Projective','7: Piecewise Poly-2'};
            methodResiduals = cell(1,7);
            for m=1:7
                methodResiduals{m} = GridComputeMethodResidual(app, grid_Position_Current, worldPoints, squareSize, m);
            end

            % One arrow scale shared across EVERY panel (before + all 7
            % methods) -- same reasoning as DistortionCorrectionTest's
            % before/after pair, just extended to all 8.
            allMag = hypot(beforeResidual(:,1), beforeResidual(:,2));
            for m=1:7
                allMag = [allMag; hypot(methodResiduals{m}(:,1), methodResiduals{m}(:,2))]; %#ok<AGROW>
            end
            maxMag = max(allMag);
            targetLenCells = 0.4;
            if maxMag > 0
                arrowScale = targetLenCells / maxMag;
            else
                arrowScale = 1;
            end

            figHandle = figure('NumberTitle','off', ...
                'Name', sprintf('Compare All Models -- Plane #%d', app.grid_PlaneCurrent));
            set(figHandle, 'Position', [60 60 1500 780]);
            subplot(2,4,1);
            GridPlotResidualVectors(app, gxIdx, gyIdx, beforeResidual, arrowScale, maxMag, 'Before (raw vs. ideal grid)');
            for m=1:7
                subplot(2,4,m+1);
                GridPlotResidualVectors(app, gxIdx, gyIdx, methodResiduals{m}, arrowScale, maxMag, methodNames{m});
            end

            overallRMS = zeros(1,7);
            maxPointRMS = zeros(1,7);
            for m=1:7
                mag = hypot(methodResiduals{m}(:,1), methodResiduals{m}(:,2));
                overallRMS(m) = sqrt(mean(mag.^2));
                maxPointRMS(m) = max(mag);
            end
            beforeMag = hypot(beforeResidual(:,1), beforeResidual(:,2));
            beforeRMS = sqrt(mean(beforeMag.^2));

            figHandle2 = figure('NumberTitle','off', ...
                'Name', sprintf('Compare All Models -- Summary (Plane #%d)', app.grid_PlaneCurrent));
            set(figHandle2, 'Position', [60 60 800 500]);
            b = bar([overallRMS; maxPointRMS]');
            b(1).DisplayName = 'Overall RMS (px)';
            b(2).DisplayName = 'Max per-point RMS (px)';
            set(gca,'XTickLabel', methodNames, 'XTickLabelRotation', 20);
            ylabel('Fit residual (px)');
            title(sprintf('Correction Model Comparison -- Plane #%d (dashed line = before, uncorrected)', app.grid_PlaneCurrent));
            legend('Location','northeast');
            grid on;
            yl = yline(beforeRMS, '--k', sprintf('Before RMS=%.2fpx', beforeRMS));
            yl.HandleVisibility = 'off'; % keep it out of the legend -- its own inline label already names it
        end

        function LoadGridSettings(app, filename)
            load(filename, 'Grid_Save');
            app.Filename_GridDistortion=filename;
            app.grid_SizeX=size(Grid_Save,1);
            app.grid_SizeY=size(Grid_Save,2);
            app.GridSizeValue.Text=[num2str(app.grid_SizeX) ' x ' num2str(app.grid_SizeY)];
            Grid_Save=reshape(Grid_Save, size(Grid_Save,1)*size(Grid_Save,2), 2,4);
            app.grid_Position=Grid_Save;
            for i=1:4
                if(app.grid_Position(1,1, i)~=-1)
                    switch(i)
                        case 1
                            app.Grid1Clear.Enable=true;
                            app.Grid1Test.Enable=true;
                        case 2
                            app.Grid2Clear.Enable=true;
                            app.Grid2Test.Enable=true;
                        case 3
                            app.Grid3Clear.Enable=true;
                            app.Grid3Test.Enable=true;
                        case 4
                            app.Grid4Clear.Enable=true;
                            app.Grid4Test.Enable=true;
                    end
                end
            end
        end

        function [new_pos,status,fitQuality] = ...
                GridPositionOptimize(app,pos,dx,dy)
        
            new_pos = pos;
            status = 0;
        
            fitQuality.rmseX = inf;
            fitQuality.rmseY = inf;
        
            [profileX,profileY,profileStatus] = ...
                GridProfile(app,pos,dx,dy);
        
            if profileStatus ~= 1
                status = profileStatus;
                return;
            end
        
            [offsetX,fitOKX,rmseX,depthX,widthX] = ...
                GridFitting(app,profileX,1);

            [offsetY,fitOKY,rmseY,depthY,widthY] = ...
                GridFitting(app,profileY,2);

            fitQuality.rmseX = rmseX;
            fitQuality.rmseY = rmseY;
            fitQuality.depthX = depthX;   % V7: exposed additively so
            fitQuality.widthX = widthX;   % GridCompareFittingMethods can
            fitQuality.depthY = depthY;   % harvest typical dip-shape
            fitQuality.widthY = widthY;   % parameters for the synthetic template

            if ~fitOKX || ~fitOKY
                status = -2;
                return;
            end
        
            if abs(offsetX) > app.fitRange || ...
               abs(offsetY) > app.fitRange
                status = -3;
                return;
            end
        
            if app.rotationOn
                gridSpacing = hypot(dx,dy);
        
                ux = dx/gridSpacing;
                uy = dy/gridSpacing;
        
                vx = -uy;
                vy =  ux;
        
                imageOffset = ...
                    offsetX*[ux uy] + ...
                    offsetY*[vx vy];
        
                new_pos = pos + imageOffset;
            else
                new_pos = pos + [offsetX offsetY];
            end
        
            status = 1;
        end        
        
        function [profileX, profileY, status] = ...
                GridProfile(app,pos,gridDx,gridDy)
        
            profileX = [];
            profileY = [];
            status = -1;
        
            imageData = double(app.ref_Image);
            [imageHeight,imageWidth] = size(imageData);
        
            gridSpacing = hypot(gridDx,gridDy);
        
            if ~isfinite(gridSpacing) || gridSpacing < 2
                status = -2;
                return;
            end
        
            % Current fitting function only supports the single-crossing mode.
            if ~app.fitOneGrid
                status = -3;
                return;
            end
        
            halfWidth = max(app.fitRange+2, ...
                            floor(0.6*gridSpacing));
        
            % Unit vector along one family of grid bars.
            ux = gridDx/gridSpacing;
            uy = gridDy/gridSpacing;
        
            % Orthogonal unit vector.
            vx = -uy;
            vy =  ux;
        
            localAxis = -halfWidth:halfWidth;
            [localX,localY] = meshgrid(localAxis,localAxis);
        
            % Map the locally aligned coordinates into image coordinates.
            queryX = pos(1) + localX*ux + localY*vx;
            queryY = pos(2) + localX*uy + localY*vy;
        
            if min(queryX,[],"all") < 1 || ...
               max(queryX,[],"all") > imageWidth || ...
               min(queryY,[],"all") < 1 || ...
               max(queryY,[],"all") > imageHeight
                status = -1;
                return;
            end
        
            patch = interp2( ...
                imageData,queryX,queryY,"linear",NaN);
        
            if any(~isfinite(patch),"all")
                status = -1;
                return;
            end
        
            % Use the mean instead of the sum so the intensity scale does not
            % depend on the patch dimensions.
            profileX = mean(patch,1);
            profileY = mean(patch,2).';
        
            status = 1;
        
            if app.debugPlot
                figure(2);
                clf;

                subplot(1,3,1);
                imagesc(localAxis,localAxis,patch);
                axis image;
                title("Aligned local patch");
        
                subplot(1,3,2);
                plot(localAxis,profileX);
                title("Horizontal profile");
        
                subplot(1,3,3);
                plot(localAxis,profileY);
                title("Vertical profile");
            end
        end

        function [offset,fitOK,fitRMSE,depth,width] = ...
                GridFitting(app,lprofile,num)

            offset = 0;
            fitOK = false;
            fitRMSE = inf;
            depth = NaN;   % V7: exposed (additively -- existing callers
            width = NaN;   % requesting fewer outputs are unaffected) so
                           % GridCompareFittingMethods can harvest typical
                           % dip shape parameters to build a synthetic
                           % cross-correlation template.

            profile = double(lprofile(:).');
        
            if isempty(profile) || ...
               any(~isfinite(profile)) || ...
               max(profile) - min(profile) <= eps
                return;
            end
        
            L = numel(profile);
            xPos = -(L-1)/2:(L-1)/2;
        
            % Normalize to make fitting bounds less dependent on crop size
            % and image intensity.
            baseline = median(profile);
            scale = max(abs(profile-baseline));
        
            if scale <= eps
                return;
            end
        
            profileNorm = (profile-baseline)/scale;
        
            model = @(p,x) ...
                p(1) ...
                - p(3)*exp(-0.5*((x-p(2))/p(4)).^2) ...
                + p(5)*x;
        
            % p = [background, center, depth, width, slope]
            lb = [
                -1, ...
                -app.fitRange, ...
                 0.02, ...
                 1, ...
                -0.2
            ];
        
            ub = [
                 1, ...
                 app.fitRange, ...
                 2, ...
                 max(2,app.fitRange), ...
                 0.2
            ];
        
            [~,minimumIndex] = min(profileNorm);
            initialCenter = xPos(minimumIndex);
        
            initialCenter = max( ...
                -app.fitRange, ...
                min(app.fitRange,initialCenter));
        
            x0 = [
                median(profileNorm), ...
                initialCenter, ...
                max(0.1,median(profileNorm)-min(profileNorm)), ...
                3, ...
                0
            ];
        
            options = optimoptions( ...
                "lsqcurvefit", ...
                "Algorithm","trust-region-reflective", ...
                "Display","off");
        
            try
                [fitParameters,resnorm,~,exitflag] = ...
                    lsqcurvefit( ...
                        model,x0,xPos,profileNorm,lb,ub,options);
            catch
                return;
            end
        
            offset = fitParameters(2);
            fitRMSE = sqrt(resnorm/L);
            depth = fitParameters(3);
            width = fitParameters(4);

            centerAtLimit = ...
                abs(abs(offset)-app.fitRange) < 0.05;
        
            sufficientDepth = fitParameters(3) > 0.05;
            reasonableWidth = ...
                fitParameters(4) > 1 && ...
                fitParameters(4) < app.fitRange;
        
            fitOK = ...
                exitflag > 0 && ...
                isfinite(offset) && ...
                ~centerAtLimit && ...
                sufficientDepth && ...
                reasonableWidth;
        
            if app.debugPlot
                figure(2);
                subplot(1,3,num+1);
                hold on;
                plot(xPos,model(fitParameters,xPos));
                hold off;
            end
        end        
        
        %% --- V7: template cross-correlation as an alternative local-fit method ---
        %
        % GridProfile/GridFitting/GridPositionOptimize above stay
        % completely unmodified in behavior. GridPositionOptimizeTemplate
        % below is a separate, parallel routine that reuses the same
        % lattice-aligned local coordinate remapping but cross-correlates
        % the raw 2D patch against a synthetic template of the expected
        % crossing shape (normxcorr2, with a 2D parabolic sub-pixel peak
        % refinement) instead of parametrically fitting marginalized 1D
        % profiles. GridCompareFittingMethods runs both methods through
        % the SAME multi-pass predict->refine->smooth-surface->reseed
        % procedure GridOptimizePlaneUntilConverged already uses for the
        % real pipeline, and reports convergence rate, fit residual, and
        % smooth-surface consistency (a ground-truth-free accuracy proxy)
        % after every pass.
        %
        % (An earlier version of this section also had a joint-2D-fit
        % method -- one parametric "additive cross" dip model fit
        % directly to the whole 2D patch via lsqcurvefit, instead of two
        % independent 1D profiles. Removed: it showed no accuracy or
        % convergence advantage over the baseline across all 8 planes of
        % real test data, and was consistently 2-3x slower.)

        function template = GridBuildCrossingTemplate(~, halfWidth, barWidthX, barWidthY)
            % Physically-motivated BINARY template: the grid is an opaque
            % mask, so a crossing is two overlapping RECTANGULAR bars
            % with sharp edges and uniform depth across their width --
            % not a pair of tapering Gaussian dips (a real crossing stays
            % dark across the whole bar width instead of fading away
            % from the center; see the side-by-side comparison that
            % motivated this). The bars are combined via a union (either
            % bar blocks the beam), matching how a physical mask works,
            % rather than additively double-darkening at the
            % intersection. Purely 0/-1: normxcorr2 z-normalizes both the
            % template and the search patch, so only the binary
            % dark/bright PATTERN carries any information -- an actual
            % depth value would be invariant and is left out entirely.
            localAxis = -halfWidth:halfWidth;
            [X, Y] = meshgrid(localAxis, localAxis);
            isBar = (abs(X) <= barWidthX/2) | (abs(Y) <= barWidthY/2);
            template = -double(isBar);
        end

        function fwhm = GridProfileFWHM(~, profile, localAxis)
            % Empirically measures the full width at half depth of a 1D
            % marginalized profile (GridProfile's profileX/profileY) --
            % a direct measurement of the physical grid-bar width, rather
            % than inferring it from a Gaussian fit's sigma (which
            % reflects imaging blur as much as the bar itself, and need
            % not equal a sharp-edged bar's real half-width).
            fwhm = NaN;
            profile = double(profile(:).');
            if numel(profile) < 5
                return;
            end
            edgeSamples = [profile(1:2) profile(end-1:end)];
            baseline = median(edgeSamples);
            [minVal, minIdx] = min(profile);
            if baseline - minVal <= eps
                return;
            end
            halfLevel = (baseline + minVal)/2;

            leftIdx = minIdx;
            while leftIdx > 1 && profile(leftIdx) < halfLevel
                leftIdx = leftIdx - 1;
            end
            rightIdx = minIdx;
            while rightIdx < numel(profile) && profile(rightIdx) < halfLevel
                rightIdx = rightIdx + 1;
            end
            if leftIdx == minIdx || rightIdx == minIdx
                return; % dip touches an edge of the profile -- can't bracket both crossings
            end

            fracL = (halfLevel - profile(leftIdx)) / (profile(leftIdx+1) - profile(leftIdx));
            xLeft = localAxis(leftIdx) + fracL*(localAxis(leftIdx+1) - localAxis(leftIdx));
            fracR = (halfLevel - profile(rightIdx-1)) / (profile(rightIdx) - profile(rightIdx-1));
            xRight = localAxis(rightIdx-1) + fracR*(localAxis(rightIdx) - localAxis(rightIdx-1));

            fwhm = xRight - xLeft;
        end

        function [offsetX, offsetY, fitOK, peakCorr] = ...
                GridFitTemplateCrossCorr(~, searchPatch, template, templateHalfWidth, searchHalfWidth)
            % Matched-filter localization: cross-correlate the search
            % patch against the synthetic template (normxcorr2), then
            % refine the integer-pixel peak to sub-pixel via a 2D
            % parabolic (separable) interpolation of its 3x3
            % neighborhood -- the standard PIV/DIC cross-correlation
            % refinement technique. The offset-recovery formula below was
            % validated against synthetic patches with known sub-pixel
            % offsets (errors <0.01px) before being wired in here.
            offsetX = 0; offsetY = 0; fitOK = false; peakCorr = -1;

            searchPatch = double(searchPatch);
            if isempty(searchPatch) || any(~isfinite(searchPatch),"all")
                return;
            end

            C = normxcorr2(template, searchPatch);
            [maxVal, maxIdx] = max(C(:));
            [peakRow, peakCol] = ind2sub(size(C), maxIdx);
            peakCorr = maxVal;

            if peakRow<=1 || peakRow>=size(C,1) || peakCol<=1 || peakCol>=size(C,2)
                return; % peak on the border -- no sub-pixel refinement possible, treat as not converged
            end

            denomRow = C(peakRow-1,peakCol) - 2*C(peakRow,peakCol) + C(peakRow+1,peakCol);
            denomCol = C(peakRow,peakCol-1) - 2*C(peakRow,peakCol) + C(peakRow,peakCol+1);
            if abs(denomRow) < eps || abs(denomCol) < eps
                return;
            end
            dRow = 0.5*(C(peakRow-1,peakCol) - C(peakRow+1,peakCol)) / denomRow;
            dCol = 0.5*(C(peakRow,peakCol-1) - C(peakRow,peakCol+1)) / denomCol;

            offsetY = (peakRow+dRow) - templateHalfWidth - searchHalfWidth - 1;
            offsetX = (peakCol+dCol) - templateHalfWidth - searchHalfWidth - 1;

            fitOK = peakCorr > 0.3 && abs(offsetX) <= searchHalfWidth-templateHalfWidth ...
                && abs(offsetY) <= searchHalfWidth-templateHalfWidth;
        end

        function [patch, localAxis, status] = ...
                GridExtractLocalPatch(app, pos, gridDx, gridDy, halfWidth)
            % General-purpose lattice-aligned 2D patch extractor -- same
            % coordinate remapping GridProfile above uses (interp2 over a
            % local axis rotated/scaled into image coordinates by the
            % grid's own local direction vectors), just returning the
            % raw 2D patch instead of marginalizing it into 1D profiles.
            % Used by GridPositionOptimizeTemplate for its search-patch
            % extraction, with halfWidth passed in explicitly (the
            % template method needs a wider patch than GridProfile's own
            % internal default, to leave normxcorr2 room to search).
            patch = [];
            localAxis = [];
            status = -1;

            imageData = double(app.ref_Image);
            [imageHeight,imageWidth] = size(imageData);

            gridSpacing = hypot(gridDx,gridDy);
            if ~isfinite(gridSpacing) || gridSpacing < 2
                status = -2;
                return;
            end

            ux = gridDx/gridSpacing;
            uy = gridDy/gridSpacing;
            vx = -uy;
            vy =  ux;

            localAxis = -halfWidth:halfWidth;
            [localX,localY] = meshgrid(localAxis,localAxis);

            queryX = pos(1) + localX*ux + localY*vx;
            queryY = pos(2) + localX*uy + localY*vy;

            if min(queryX,[],"all") < 1 || ...
               max(queryX,[],"all") > imageWidth || ...
               min(queryY,[],"all") < 1 || ...
               max(queryY,[],"all") > imageHeight
                status = -1;
                return;
            end

            patch = interp2(imageData,queryX,queryY,"linear",NaN);
            if any(~isfinite(patch),"all")
                status = -1;
                return;
            end

            status = 1;
        end

        function [new_pos, status, fitQuality] = ...
                GridPositionOptimizeTemplate(app, pos, dx, dy, template, templateHalfWidth)
            % Mirrors GridPositionOptimize's structure/return convention,
            % but localizes via matched-filter cross-correlation against
            % a pre-built synthetic template instead of a parametric fit.
            % The search patch is deliberately larger than the template
            % so normxcorr2 has room to find the best-aligned position
            % within it.
            new_pos = pos;
            status = 0;
            fitQuality.peakCorr = -1;

            gridSpacing = hypot(dx,dy);
            searchHalfWidth = templateHalfWidth + app.fitRange;

            [searchPatch, ~, patchStatus] = GridExtractLocalPatch(app, pos, dx, dy, searchHalfWidth);
            if patchStatus ~= 1
                status = patchStatus;
                return;
            end

            [offsetX, offsetY, fitOK, peakCorr] = ...
                GridFitTemplateCrossCorr(app, searchPatch, template, templateHalfWidth, searchHalfWidth);
            fitQuality.peakCorr = peakCorr;

            if ~fitOK
                status = -2;
                return;
            end

            if app.rotationOn
                ux = dx/gridSpacing; uy = dy/gridSpacing;
                vx = -uy; vy = ux;
                new_pos = pos + offsetX*[ux uy] + offsetY*[vx vy];
            else
                new_pos = pos + [offsetX offsetY];
            end
            status = 1;
        end

        function [sfX, sfY, surfaceOrder] = GridFitSurfaceReadOnly(~, gx, gy, posXY, goodMask)
            % Read-only version of the same robust polynomial surface fit
            % GridFitSmoothSurface uses -- returns the fitted sfX/sfY
            % objects themselves (not just a residual), so callers like
            % GridMultiPassRefine can also evaluate them at every grid
            % index (to reseed the next pass) without touching
            % app.grid_Position/grid_SurfaceModel. sfX/sfY come back
            % empty if there aren't enough points to fit anything.
            sfX = []; sfY = []; surfaceOrder = '';
            nGood = nnz(goodMask);
            if nGood < 6
                return;
            elseif nGood < 15
                surfaceOrder = 'poly11';
            elseif nGood < 30
                surfaceOrder = 'poly22';
            else
                surfaceOrder = 'poly23';
            end

            warnState = warning('off','curvefit:fit:iterationLimitReached');
            sfX = fit([gx(goodMask) gy(goodMask)], posXY(goodMask,1), surfaceOrder, 'Robust','Bisquare');
            sfY = fit([gx(goodMask) gy(goodMask)], posXY(goodMask,2), surfaceOrder, 'Robust','Bisquare');
            warning(warnState);
        end

        function rmsResid = GridSurfaceResidualRMS(app, gx, gy, posXY, goodMask)
            % Read-only diagnostic: fits the same kind of robust
            % polynomial surface GridFitSmoothSurface uses, purely to
            % measure how internally consistent a candidate position set
            % is with a smooth physical grid -- never touches
            % app.grid_Position/grid_Info. Used by
            % GridCompareFittingMethods as a ground-truth-free accuracy
            % proxy (real data has no independently-known true position
            % to compare against).
            rmsResid = NaN;
            [sfX, sfY] = GridFitSurfaceReadOnly(app, gx, gy, posXY, goodMask);
            if isempty(sfX)
                return;
            end
            predX = sfX(gx(goodMask), gy(goodMask));
            predY = sfY(gx(goodMask), gy(goodMask));
            resid = hypot(posXY(goodMask,1)-predX, posXY(goodMask,2)-predY);
            rmsResid = sqrt(mean(resid.^2));
        end

        function [newPos, status] = GridBaselineStep(app, seedPos, dx1, dy1)
            % Thin wrapper so the baseline method matches the
            % (newPos,status) optimizeFcn convention GridMultiPassRefine
            % expects -- GridPositionOptimize itself is left completely
            % unmodified, this just drops its 3rd output (fitQuality).
            [newPos, status, ~] = GridPositionOptimize(app, seedPos, dx1, dy1);
        end

        function [newPos, status] = GridTemplateStep(app, seedPos, dx1, dy1, dx2, dy2, ratioX, ratioY)
            % Per-point wrapper used as GridMultiPassRefine's optimizeFcn
            % for the template method: builds a FRESH template at this
            % point's own LOCAL period (from whichever model the current
            % pass is seeding from -- bare on pass 1, surface-enriched
            % from pass 2 on, same as the position seed itself) times the
            % once-calibrated width/period ratio, then localizes via
            % cross-correlation against it.
            localD1 = hypot(dx1, dy1);
            localD2 = hypot(dx2, dy2);
            localBarWidthX = ratioX * localD1;
            localBarWidthY = ratioY * localD2;
            localHalfWidth = max(app.fitRange+2, floor(0.6*localD1));
            pointTemplate = GridBuildCrossingTemplate(app, localHalfWidth, localBarWidthX, localBarWidthY);
            [newPos, status, ~] = GridPositionOptimizeTemplate(app, seedPos, dx1, dy1, pointTemplate, localHalfWidth);
        end

        function history = GridMultiPassRefine(app, plane, latticeModel, optimizeFcn, maxPasses)
            % Generic, read-only re-implementation of the SAME
            % predict->refine->smooth-surface->reseed loop
            % GridOptimizePlaneUntilConverged/GridPopulatePlaneAuto
            % already run for the app's real pipeline -- parameterized by
            % an arbitrary per-point optimizer function handle
            % optimizeFcn(seedPos,dx1,dy1,dx2,dy2)->(newPos,status), so
            % the exact same multi-pass procedure can be run with a
            % different local-fit method (here, the template) without
            % ever touching app.grid_Position/grid_Info/grid_SurfaceModel.
            % Mirrors the real stopping rule: stop once the number of
            % converged points stops improving, hits ~98%, or maxPasses
            % is reached. Returns a struct array, one element per pass
            % actually run, each holding that pass's RAW (pre-final-
            % surface-overwrite) fitted positions/convergence plus the
            % surface-consistency residual computed from them -- the
            % same quantities GridCompareFittingMethods needs to show how
            % each method evolves pass over pass.
            nTotal = app.grid_SizeX*app.grid_SizeY;
            gx = zeros(nTotal,1); gy = zeros(nTotal,1);
            for grid_y=1:app.grid_SizeY
                for grid_x=1:app.grid_SizeX
                    index=(grid_y-1)*app.grid_SizeX+grid_x;
                    gx(index)=grid_x; gy(index)=grid_y;
                end
            end

            currentModel = latticeModel;
            prevGoodCount = -1;
            history = struct('pos',{},'ok',{},'convPct',{},'surfResid',{});

            for pass = 1:maxPasses
                pos = nan(nTotal,2); ok = false(nTotal,1);
                for k = 1:nTotal
                    seedPos = GridPredictPosition(app, currentModel, gx(k), gy(k));
                    [dx1, dy1] = GridLatticeLocalSpacing(app, currentModel, gx(k), gy(k), 1);
                    [dx2, dy2] = GridLatticeLocalSpacing(app, currentModel, gx(k), gy(k), 2);
                    [newPos, status] = optimizeFcn(seedPos, dx1, dy1, dx2, dy2);
                    pos(k,:) = newPos;
                    ok(k) = (status==1);
                end

                [sfX, sfY] = GridFitSurfaceReadOnly(app, gx, gy, pos, ok);
                surfResid = GridSurfaceResidualRMS(app, gx, gy, pos, ok);
                nGoodNow = nnz(ok);
                history(end+1) = struct('pos',pos, 'ok',ok, ... %#ok<AGROW>
                    'convPct',round(100*nGoodNow/nTotal), 'surfResid',surfResid);

                if isempty(sfX) || nGoodNow <= prevGoodCount || nGoodNow >= nTotal*0.98
                    break; % no surface to reseed from, no more improvement, or effectively fully converged
                end
                prevGoodCount = nGoodNow;

                predX = sfX(gx,gy); predY = sfY(gx,gy);
                dx1g = (sfX(gx+1,gy) - sfX(gx-1,gy))/2; dy1g = (sfY(gx+1,gy) - sfY(gx-1,gy))/2;
                dx2g = (sfX(gx,gy+1) - sfX(gx,gy-1))/2; dy2g = (sfY(gx,gy+1) - sfY(gx,gy-1))/2;
                currentModel.predictedPos = [predX predY];
                currentModel.localSpacing = {[dx1g dy1g], [dx2g dy2g]};
            end
        end

        function results = GridCompareFittingMethods(app, plane)
            % Runs the existing baseline (GridPositionOptimize) and the
            % template cross-correlation (GridPositionOptimizeTemplate)
            % through the SAME multi-pass procedure the real pipeline
            % uses (GridMultiPassRefine), both starting from identical
            % lattice-predicted seeds, then reports convergence rate and
            % smooth-surface consistency AFTER EVERY PASS for each --
            % not just a single cold-start pass -- so it's possible to
            % see whether one method's edge over the other holds up,
            % grows, or disappears once both get the same benefit of
            % iterative reseeding from an improving surface fit. Entirely
            % read-only, never modifies app.grid_Position/grid_Info.
            results = [];
            if numel(app.grid_LatticeModel) < plane || isempty(app.grid_LatticeModel{plane})
                fprintf('[GridCorrection] No lattice model available for plane %d -- run Quick Setup / Populate the Rest first.\n', plane);
                return;
            end
            latticeModel = app.grid_LatticeModel{plane};
            nTotal = app.grid_SizeX*app.grid_SizeY;
            gx = zeros(nTotal,1); gy = zeros(nTotal,1);
            for grid_y=1:app.grid_SizeY
                for grid_x=1:app.grid_SizeX
                    index=(grid_y-1)*app.grid_SizeX+grid_x;
                    gx(index)=grid_x; gy(index)=grid_y;
                end
            end

            % Calibrate the width/period ratio ONCE, from a single
            % cold-start baseline pass -- it's a property of the physical
            % mask, not expected to change plane-to-plane or pass-to-pass.
            fwhmXList = []; fwhmYList = [];
            for k=1:nTotal
                estimatedPos = GridPredictPosition(app, latticeModel, gx(k), gy(k));
                [xdx, xdy] = GridLatticeLocalSpacing(app, latticeModel, gx(k), gy(k), 1);
                [~, fitStatus, ~] = GridPositionOptimize(app, estimatedPos, xdx, xdy);
                if fitStatus==1
                    [profileX, profileY, profileStatus] = GridProfile(app, estimatedPos, xdx, xdy);
                    if profileStatus == 1
                        halfWidthProfile = (numel(profileX)-1)/2;
                        profileAxis = -halfWidthProfile:halfWidthProfile;
                        fwhmX = GridProfileFWHM(app, profileX, profileAxis);
                        fwhmY = GridProfileFWHM(app, profileY, profileAxis);
                        if isfinite(fwhmX), fwhmXList(end+1) = fwhmX; end %#ok<AGROW>
                        if isfinite(fwhmY), fwhmYList(end+1) = fwhmY; end %#ok<AGROW>
                    end
                end
            end
            if isempty(fwhmXList) || isempty(fwhmYList)
                ratioX = 0.25; ratioY = 0.25; % sane fallback (typical open-mesh duty cycle) if nothing converged at all
            else
                ratioX = median(fwhmXList) / latticeModel.d1;
                ratioY = median(fwhmYList) / latticeModel.d2;
            end

            maxPasses = max(app.grid_RefinementPasses, 4);
            baselineFcn = @(seedPos,dx1,dy1,dx2,dy2) GridBaselineStep(app, seedPos, dx1, dy1);
            templateFcn = @(seedPos,dx1,dy1,dx2,dy2) GridTemplateStep(app, seedPos, dx1, dy1, dx2, dy2, ratioX, ratioY);

            tBaseline = tic;
            baselineHistory = GridMultiPassRefine(app, plane, latticeModel, baselineFcn, maxPasses);
            timeBaseline = toc(tBaseline);

            tTemplate = tic;
            templateHistory = GridMultiPassRefine(app, plane, latticeModel, templateFcn, maxPasses);
            timeTemplate = toc(tTemplate);

            fprintf('[GridCorrection] === Multi-pass fitting comparison (plane %d, %d points) ===\n', plane, nTotal);
            fprintf('[GridCorrection] Template width/period ratio: %.3f x %.3f (calibrated from %d/%d converged fits)\n', ...
                ratioX, ratioY, numel(fwhmXList), numel(fwhmYList));
            fprintf('%6s | %-24s | %-24s\n', 'Pass', 'Baseline (1D x2)', 'Template cross-corr');
            fprintf('%6s | %8s %14s | %8s %14s\n', '', 'Conv%', 'SurfResid', 'Conv%', 'SurfResid');
            nPasses = max(numel(baselineHistory), numel(templateHistory));
            for p = 1:nPasses
                if p <= numel(baselineHistory)
                    bStr = sprintf('%7d%% %14.4f', baselineHistory(p).convPct, baselineHistory(p).surfResid);
                else
                    bStr = sprintf('%7s %14s', '--', '--');
                end
                if p <= numel(templateHistory)
                    tStr = sprintf('%7d%% %14.4f', templateHistory(p).convPct, templateHistory(p).surfResid);
                else
                    tStr = sprintf('%7s %14s', '--', '--');
                end
                fprintf('%6d | %s | %s\n', p, bStr, tStr);
            end
            fprintf('[GridCorrection] Lower SurfResid = positions collectively more consistent with a smooth\n');
            fprintf('[GridCorrection] physical grid (no external ground truth available, so this is the best proxy).\n');
            fprintf('[GridCorrection] Baseline: %d pass(es), %.2fs total. Template: %d pass(es), %.2fs total.\n', ...
                numel(baselineHistory), timeBaseline, numel(templateHistory), timeTemplate);

            results = struct( ...
                'baseline', baselineHistory, 'baselineTime', timeBaseline, ...
                'template', templateHistory, 'templateTime', timeTemplate, ...
                'ratioX', ratioX, 'ratioY', ratioY, 'plane', plane, 'gx', gx, 'gy', gy);
            app.GridLastCompareResults = results;
        end

        function [dx, dy] = GridPositionFindOffset(~, pos1, pos2)
            dx=pos2(1)-pos1(1);
            dy=pos2(2)-pos1(2);
        end
        
        function FlattenImage(app)
            app.ref_Image(app.ref_Image>3)=3;
        end
        
        function SetGridPlaneParameter(app)
            % V5: no-op -- the computed end-plane value is now derived
            % fresh every time inside BuildViewModel (gridPlaneEnd) rather
            % than written into a display-only uicontrol here. Kept as a
            % function (instead of deleting it) so its call sites don't
            % need to change.
        end
        
        function GridInitialization(app)
            % V5: grid_SizeX/Y/Z are kept current directly by the HTML
            % form's field-change events (see GridSizeXEditFieldValueChanged
            % etc.), so there's no uicontrol.Value to re-read here anymore.
            GridSize=app.grid_SizeX*app.grid_SizeY;

            app.grid_Position=zeros(GridSize,2,app.grid_SizeZ); %index, xy, z
            
            for index=1:GridSize
                for z=1:app.grid_SizeZ
                    app.grid_Position(index,:,z)=[-1 -1];
                end
            end
            
            app.grid_Info{GridSize, app.grid_SizeZ}=[];

            for index=1:GridSize
                for z=1:app.grid_SizeZ
                    app.grid_Info{index,z}.Status=-1;
                end
            end

        end
        
        function GridChangeDisplayPlane(app)
            ChangeRefImagePlane(app);

            EnterGridEditorMode(app); % idempotent -- switches the shared figure into editor view
                                       % once, safe to call again if already there
            app.ImageCorrectionDialogUIFigure.Name = sprintf('Image Correction Dialog -- Grid Plane #%d', app.grid_PlaneCurrent);

            imshow(app.ref_Image, [0 3], 'Parent', app.GridAxes);
            % Pin the display tightly to the actual image extent --
            % imshow does this by default, but the ~100 drawpoint ROIs
            % added below can silently auto-expand the axes limits if any
            % point lands even slightly outside the image (e.g. an
            % edge-of-field grid index whose predicted position falls a
            % few px past the frame), stretching the visible canvas and
            % leaving a large empty margin between the image and
            % whatever's docked next to it.
            app.GridAxes.XLim = [0.5, size(app.ref_Image,2)+0.5];
            app.GridAxes.YLim = [0.5, size(app.ref_Image,1)+0.5];
            for grid_y=1:app.grid_SizeY
                for grid_x=1:app.grid_SizeX
                    index=(grid_y-1)*app.grid_SizeX+grid_x;
                    pos=app.grid_Position(index, :, app.grid_PlaneCurrent);
                    info = app.grid_Info{index, app.grid_PlaneCurrent};
                    if isfield(info,'source') && strcmp(info.source,'z-trend')
                        % Corrected via cross-plane (Z) correlation because
                        % this point/plane wasn't trustworthy on its own --
                        % shown distinctly so it's clear which points were
                        % filled in this way, versus directly measured.
                        app.fig_GridHandle{index}.handle = drawpoint(app.GridAxes, 'Position',pos, 'Color', [0.2 0.8 1]);
                    else
                        switch(info.status)
                            case 1
                                app.fig_GridHandle{index}.handle = drawpoint(app.GridAxes, 'Position',pos);
                            case 2
                                app.fig_GridHandle{index}.handle = drawpoint(app.GridAxes, 'Position',pos, 'Color', [1 0.55 0.75]);
                            otherwise
                                app.fig_GridHandle{index}.handle = drawpoint(app.GridAxes, 'Position',pos, 'Color', [1 0.2 0.75]);
                        end
                    end
                    app.fig_GridHandle{index}.handle.Tag=int2str(index);
                    addlistener(app.fig_GridHandle{index}.handle,'ROIMoved', @(varargin)GridPositionMoved(app, varargin));

                    % Right-click on a point normally opens the ROI's
                    % built-in context menu, whose only entry is
                    % "Delete" -- not a meaningful action here (it would
                    % just leave a hole in the grid). Replace it
                    % entirely: no menu at all, right-click (or
                    % ctrl-click) directly triggers a local refine, no
                    % extra click needed -- reruns the same bounded
                    % local Gaussian-dip search this point already went
                    % through, seeded from wherever it currently sits.
                    % Useful after a manual drag that landed close but
                    % not exactly on the true crossing, or any time a
                    % point looks slightly off.
                    app.fig_GridHandle{index}.handle.Deletable = false; % also blocks Delete/Backspace
                    app.fig_GridHandle{index}.handle.ContextMenu = []; % no menu -- the click itself is the action
                    addlistener(app.fig_GridHandle{index}.handle, 'ROIClicked', ...
                        @(src,evt) GridPointClicked(app, index, evt));
                end
            end
        end

        function EnterGridEditorMode(app)
            % Switches the shared figure from the dashboard (MainUI) to
            % the interactive grid-point editor (GridAxes + GridSidebarUI)
            % -- idempotent, safe to call on every GridChangeDisplayPlane/
            % ConfirmGridOriginAndRefine, same spirit as the old
            % GridSetupSidebar's one-time figure(1) setup.
            if ~app.ui_GridEditorMode
                app.ui_GridEditorMode = true;
                app.MainUI.Visible = 'off';
                app.GridAxes.Visible = 'on';
                app.GridSidebarUI.Visible = 'on';
                figPos = app.ImageCorrectionDialogUIFigure.Position;
                app.ImageCorrectionDialogUIFigure.Position = [figPos(1) figPos(2) 1150 850];
                % These may have been set with an early-status Enable=off
                % equivalent from before the editor was ever opened --
                % sync them to whatever status already applies.
                GridSettingStatusChange(app, app.grid_SettingStatus);
            end
            LayoutGridEditor(app);
        end

        function ExitGridEditorMode(app)
            % Reverses EnterGridEditorMode -- back to the dashboard, same
            % window. Wired as GridSidebarUI's "Back to Grid Setup" and
            % "Finish" actions (Finish additionally requests a one-time
            % navigate-to-Home via ui_MainUINavigateToken/To, set by the
            % caller before this runs).
            app.ui_GridEditorMode = false;
            app.GridAxes.Visible = 'off';
            app.GridSidebarUI.Visible = 'off';
            app.MainUI.Visible = 'on';
            figPos = app.ImageCorrectionDialogUIFigure.Position;
            app.ImageCorrectionDialogUIFigure.Position = [figPos(1) figPos(2) 480 900];
            app.ImageCorrectionDialogUIFigure.Name = 'Image Correction Dialog';
            PushViewModel(app); % refresh the dashboard's grid status text
        end

        function LayoutGridEditor(app)
            % Positions GridAxes and GridSidebarUI side by side, filling
            % the figure -- called on entry and on every resize (see
            % ImageCorrectionDialogUIFigureSizeChanged). Unlike the old
            % pixel-math GridLayoutSidebar, the sidebar's INTERNAL layout
            % is plain HTML/CSS (flexbox) -- MATLAB only needs to give
            % each component its outer rectangle.
            if ~app.ui_GridEditorMode
                return;
            end
            sidebarWidthPx = 312; % +20% from the original 260
            marginPx = 10;
            gapPx = 4; % half of the original 8 -- sidebar sits closer to the image
            minImageWidthPx = 320;
            minFigHeightPx = 420;

            % Enforce a minimum window size the same way the old
            % GridLayoutSidebar did: clamp and let the resulting Position
            % write re-trigger this via SizeChangedFcn.
            minFigWidthPx = marginPx + minImageWidthPx + gapPx + sidebarWidthPx + marginPx;
            figPos = app.ImageCorrectionDialogUIFigure.Position;
            if figPos(3) < minFigWidthPx || figPos(4) < minFigHeightPx
                app.ImageCorrectionDialogUIFigure.Position = [figPos(1), figPos(2), ...
                    max(figPos(3),minFigWidthPx), max(figPos(4),minFigHeightPx)];
                return;
            end

            sidebarLeftPx = figPos(3) - marginPx - sidebarWidthPx;
            imgWidthPx = sidebarLeftPx - gapPx - marginPx;

            app.GridAxes.Position = [marginPx, marginPx, imgWidthPx, figPos(4)-2*marginPx];
            app.GridSidebarUI.Position = [sidebarLeftPx, marginPx, sidebarWidthPx, figPos(4)-2*marginPx];
        end

        function GridUpdatePlaneLabel(app)
            % The plane counter ("N / M") now lives in GridSidebarUI's
            % view model rather than a uicontrol -- guarded the same way
            % as before, since this can run before the editor is open yet.
            if app.ui_GridEditorMode
                PushGridEditorViewModel(app);
            end
        end

        function txt = GridNormalInstructionsText(app)
            % State-aware workflow guidance -- what to do next changes
            % once every plane has been populated.
            if app.grid_SettingStatus < 4
                txt = ['Review this plane''s points below (drag a point to move it manually, or ' ...
                    'right-click a point to auto-refine its position locally). If the whole plane ' ...
                    'looks shifted, use "Adjust Grid Origin" to realign it, or "Optimize ' ...
                    'This Plane" to re-run refinement on every point here. Once this plane looks ' ...
                    'correct, click "Populate the Rest" below to process every other plane.'];
            else
                txt = ['Every plane has been populated. Use the plane navigation above to spot-check ' ...
                    'others -- drag or right-click any point that looks off, or use "Optimize This ' ...
                    'Plane" to re-run refinement on the plane shown. Click "Finish" below when ' ...
                    'you''re satisfied.'];
            end
        end


        function GridPointClicked(app, index, evt)
            % images.roi.ROIClickedEventData.SelectionType is one of
            % 'left'|'right'|'double'|'shift'|'ctrl'|'alt'|'middle' --
            % NOT the figure-level 'normal'/'alt'/'extend'/'open' set.
            % 'alt' here means "left-click with the Alt key held", not a
            % right-click -- 'right' is the actual right-click value.
            % Left-click/drag is already handled entirely by the ROI's
            % own built-in dragging plus the ROIMoved listener above, so
            % only react here for an actual right-click.
            if strcmp(evt.SelectionType, 'right')
                GridRefinePointLocal(app, index, app.grid_PlaneCurrent);
            end
        end

        function GridRefinePointLocal(app, index, plane)
            % Re-run the same bounded local Gaussian-dip search
            % (GridPositionOptimize) this point already went through,
            % but seeded from wherever it CURRENTLY sits rather than the
            % original lattice prediction -- so this doubles as "snap to
            % the nearest real crossing" after a manual drag that landed
            % close but not exactly on the true dip.
            gridY = floor((index-1)/app.grid_SizeX) + 1;
            gridX = index - (gridY-1)*app.grid_SizeX;

            currentPos = app.grid_Position(index,:,plane);
            latticeModel = GridLatticeFromCurrentPositions(app, plane);
            localDir1 = latticeModel.localSpacing{1}(index,:);
            [newPos, fitStatus, fitQuality] = GridPositionOptimize(app, currentPos, localDir1(1), localDir1(2));

            usedFallback = false;
            if fitStatus ~= 1
                % No real dip near where the point currently sits --
                % fall back to a rough position estimate from the
                % SURROUNDING grid points instead: the robust
                % within-plane surface trend if this plane has one
                % (ignores this point's own possibly-wrong position
                % entirely, purely a function of its neighbors), else
                % the raw uniform-lattice prediction. Try once more from
                % there before giving up.
                fallbackPos = [];
                if numel(app.grid_SurfaceModel) >= plane && ~isempty(app.grid_SurfaceModel{plane})
                    surfaceModel = app.grid_SurfaceModel{plane};
                    fallbackPos = [surfaceModel.sfX(gridX,gridY), surfaceModel.sfY(gridX,gridY)];
                elseif numel(app.grid_LatticeModel) >= plane && ~isempty(app.grid_LatticeModel{plane})
                    fallbackPos = GridPredictPosition(app, app.grid_LatticeModel{plane}, gridX, gridY);
                end
                if ~isempty(fallbackPos)
                    [newPos, fitStatus, fitQuality] = GridPositionOptimize(app, fallbackPos, localDir1(1), localDir1(2));
                    usedFallback = true;
                end
            end

            if fitStatus == 1
                app.grid_Position(index,:,plane) = newPos;
                app.grid_Info{index,plane}.rawPos = newPos;
                app.grid_Info{index,plane}.fitOK = true;
                app.grid_Info{index,plane}.fitRMSE = fitQuality;
                app.grid_Info{index,plane}.source = 'lattice';
                app.grid_Info{index,plane}.status = 1;
                if numel(app.fig_GridHandle) >= index && isvalid(app.fig_GridHandle{index}.handle)
                    app.fig_GridHandle{index}.handle.Position = newPos;
                    app.fig_GridHandle{index}.handle.Color = [0 0.4470 0.7410]; % back to the normal "good" color
                end
                if usedFallback
                    GridLog(app, ['Plane %d, point %d: no crossing near its current position -- refined from a ' ...
                        'neighbor-based estimate instead, landed at [%.2f, %.2f].'], plane, index, newPos(1), newPos(2));
                else
                    GridLog(app, 'Plane %d, point %d: refined locally to [%.2f, %.2f].', plane, index, newPos(1), newPos(2));
                end
            else
                GridLog(app, ['Plane %d, point %d: no clear crossing found nearby, even from a neighbor-based ' ...
                    'estimate -- position left unchanged.'], plane, index);
                uialert(app.ImageCorrectionDialogUIFigure, ...
                    sprintf('No clear crossing found near this point (plane %d), even using a neighbor-based estimate. Position left unchanged.', plane), ...
                    'Refine Position', 'Icon','warning');
            end
        end
        
        function slide_num=GridPlaneSlideNumber(app, plane)
            slide_num=app.grid_PlaneStart+(plane-1)*app.grid_PlaneInterval;
        end


        function [RA, worldPoints, squareSize] = GridTransformationInitialize(app, gridPlane)

            grid_Position_Current=app.grid_Position(:,:,gridPlane);
                
            squareSize = norm(grid_Position_Current(1,:)-grid_Position_Current(app.grid_SizeX,:))/(app.grid_SizeX-1);
            squareSize = ceil(squareSize); 

            worldPoints = generateCheckerboardPoints([app.grid_SizeX+1 app.grid_SizeY+1], squareSize);
            worldPoints = flip(worldPoints,2);  %exchange x and y axis in world points
                
%                dy=(grid_Position_Current(app.grid_SizeY,2)-grid_Position_Current(1,2));
%                if(dy==0)
%                    angle=0;
%                else
%                    angle=atan((grid_Position_Current(app.grid_SizeY,1)-grid_Position_Current(1,1))/(grid_Position_Current(app.grid_SizeY,2)-grid_Position_Current(1,2)));
%                end

%                if(angle<0.1)
%                    angle = 0.1;
%                end
                
%                outputLength=floor(max(size(app.ref_Image))/cos(angle));
%                sizeOutput = [outputLength outputLength];

            sizeInput = size(app.ref_Image);
            sizeOutput = size(app.ref_Image);
                
%                topMargin=grid_Position_Current(1,2);
%                bottomMargin=sizeInput(2)-topMargin;
                
%                leftMargin=grid_Position_Current(1,1);
%                rightMargin=sizeInput(1)-leftMargin;
                
                %try to keep output image centered vertically similarly to the original image

            % topMargin/bottomMargin are a Y (vertical) split, so they must
            % be measured against the image HEIGHT -- sizeInput(1), not
            % sizeInput(2) (width) as this previously read. Likewise
            % leftMargin/rightMargin are an X (horizontal) split and must
            % use the WIDTH, sizeInput(2), not sizeInput(1). The two were
            % swapped, which only stayed invisible for a square image.
            topMargin=grid_Position_Current(1,2);
            bottomMargin=sizeInput(1)-topMargin;

            leftMargin=grid_Position_Current(1,1);
            rightMargin=sizeInput(2)-leftMargin;

            yWorldLimits = [-topMargin+app.image_OutputShiftY bottomMargin+app.image_OutputShiftY];
            xWorldLimits = [-leftMargin-app.image_OutputShiftX rightMargin-app.image_OutputShiftX];
            % imref2d's imageSize argument is [rows cols], the same order
            % as size(I) -- it does NOT get flipped to match x/y world
            % coordinate order. flip(sizeOutput) here previously handed it
            % [cols rows] instead, so a non-square output canvas came out
            % transposed (verified: for a 721x701 image this produced
            % RA.ImageSize=[701 721]).
            RA = imref2d(sizeOutput,xWorldLimits,yWorldLimits);

        end

        function gcTransformSet = GridBuildGCTransforms(app, grid_Position_Spline, worldPoints, squareSize, imgSizeZ, zList)
            % Precomputes every Z-slide's GC geometric transform(s) once,
            % shared by CorrectImagesButtonPushed (reused across every file
            % in a folder) and GridVerifyOverallCorrection (a single
            % reference-image re-check) -- factored out so both apply
            % exactly the same transform-fitting logic instead of two
            % copies drifting apart over time.
            %
            % zList (optional) restricts fitting to just those slide
            % indices; the cells stay sized for the full imgSizeZ so
            % GridApplyGCTransform can keep indexing by iZ, the unlisted
            % entries are simply left empty. Verification only ever warps
            % the handful of slides inside the grid planes' own averaging
            % windows, so fitting all imgSizeZ transforms for it is mostly
            % wasted work -- especially for the piecewise methods, which
            % fit iL*jL (e.g. 25) transforms per slide.
            if nargin < 6 || isempty(zList)
                zList = 1:imgSizeZ;
            end
            zList = reshape(zList, 1, []); % "for iZ=zList" iterates COLUMNS, so it must be a row
            % Any cached sample grids belong to the PREVIOUS set of
            % transforms (different method, edited grid points, different
            % stack) -- drop them rather than risk reusing a stale one.
            app.gc_SampleGridCache = struct('Xq',{cell(1,imgSizeZ)}, 'Yq',{cell(1,imgSizeZ)}, 'stored',0);
            transformationMethod=str2double(app.ui_TransformationMethod);
            gcTransformSet=struct('method',transformationMethod);
            if(transformationMethod<5)
                gcTformByZ=cell(1, imgSizeZ);
                for iZ=zList
                    switch(transformationMethod)
                        case 1
                            gcTformByZ{iZ} = fitgeotrans(grid_Position_Spline(:,:,iZ),worldPoints,"affine");
                        case 2
                            gcTformByZ{iZ} = fitgeotrans(grid_Position_Spline(:,:,iZ),worldPoints,"projective");
                        case 3
                            gcTformByZ{iZ} = fitgeotrans(grid_Position_Spline(:,:,iZ),worldPoints,"polynomial", 3);
                        case 4
                            gcTformByZ{iZ} = fitgeotrans(grid_Position_Spline(:,:,iZ),worldPoints,"polynomial", 4);
                    end
                end
                gcTransformSet.tformByZ=gcTformByZ;
            else
                % Piecewise correction (methods 5-7): the block tiling
                % layout (which grid points fall in which block, and where
                % each block's output lands) depends only on the grid size
                % and worldPoints, both fixed -- compute it once. Only each
                % block's tform actually varies by iZ (via
                % grid_Position_Spline), so that's the only part
                % precomputed per-iZ below.
                mini_ImageSize=2*squareSize;
                RA_mini = imref2d([mini_ImageSize mini_ImageSize]);
                miniWorldPoints = generateCheckerboardPoints([4 4], squareSize);
                miniWorldPoints = flip(miniWorldPoints,2);  %exchange x and y axis in world points

                % ceil()+clamping instead of floor() so an even
                % grid_SizeX/Y (e.g. this app's default, 10) doesn't drop
                % the last column/row of output.
                iL=ceil((app.grid_SizeX-1)/2);
                jL=ceil((app.grid_SizeY-1)/2);

                blockWorldIdx=cell(jL,iL);
                xOutputByBlock=cell(jL,iL);
                yOutputByBlock=cell(jL,iL);
                miniOutputPosition=zeros(9,2);
                for j=1:jL
                    for i=1:iL
                        i_current=min(1+(i-1)*2, app.grid_SizeX-2);
                        j_current=min(1+(j-1)*2, app.grid_SizeY-2);
                        idxWorldBlock=zeros(9,1);
                        for n=1:3
                            for m=1:3
                                index_mini=m+(n-1)*3;
                                idxWorldBlock(index_mini)=i_current+m-1+(j_current+n-2)*app.grid_SizeX;
                                miniOutputPosition(index_mini,:)=worldPoints(idxWorldBlock(index_mini),:);
                            end
                        end
                        blockWorldIdx{j,i}=idxWorldBlock;
                        xOutputByBlock{j,i}=[miniOutputPosition(1,2) miniOutputPosition(end,2)];
                        yOutputByBlock{j,i}=[miniOutputPosition(1,1) miniOutputPosition(end,1)];
                    end
                end

                % Tried and rejected: handing imwarp only the crop window
                % each block can read from (its output view's corners
                % mapped back through the transform) instead of the whole
                % raw image. Measured on the real 901x901 data it was
                % actually SLOWER for method 5 (0.8x) and only 1.2x for
                % method 6 -- imwarp already restricts its work to the
                % output view, so the crop just added setup overhead. It
                % was also outright WRONG for method 7: a polynomial's
                % mapped region bulges outside the bounding box of its
                % mapped corners, so the crop clipped real pixels
                % (maxAbsDiff 1.7 vs the full-image warp).
                gcTformByZ=cell(imgSizeZ, jL, iL);
                for iZ=zList
                    grid_Position_Current=grid_Position_Spline(:,:,iZ);
                    for j=1:jL
                        for i=1:iL
                            miniGridPosition=grid_Position_Current(blockWorldIdx{j,i},:);
                            switch(transformationMethod)
                                case 5
                                    gcTformByZ{iZ,j,i} = fitgeotrans(miniGridPosition,miniWorldPoints,"affine");
                                case 6
                                    gcTformByZ{iZ,j,i} = fitgeotrans(miniGridPosition,miniWorldPoints,"projective");
                                case 7
                                    gcTformByZ{iZ,j,i} = fitgeotrans(miniGridPosition,miniWorldPoints,"polynomial", 2);
                            end
                        end
                    end
                end
                % Sample points for one block's output tile, in that
                % block's mini world coordinates (RA_mini's pixel centers
                % are 1..mini_ImageSize on both axes). Identical for every
                % block and every Z, so it's built once here and reused by
                % GridApplyGCTransform.
                [miniCol, miniRow] = meshgrid(1:mini_ImageSize, 1:mini_ImageSize);
                gcTransformSet.miniPts=[miniCol(:) miniRow(:)];
                gcTransformSet.mini_ImageSize=mini_ImageSize;

                gcTransformSet.tformByZ=gcTformByZ;
                gcTransformSet.xOutputByBlock=xOutputByBlock;
                gcTransformSet.yOutputByBlock=yOutputByBlock;
                gcTransformSet.RA_mini=RA_mini;
                gcTransformSet.iL=iL;
                gcTransformSet.jL=jL;
                gcTransformSet.outputSize=[(app.grid_SizeY-1)*squareSize, (app.grid_SizeX-1)*squareSize];
            end
        end

        function correctedImage = GridApplyGCTransform(app, gcTransformSet, LocalrawImage, RA, iZ)
            % Applies the transform(s) GridBuildGCTransforms already fit
            % for this iZ to one raw image -- the only part of GC
            % correction that's genuinely per-image (imwarp itself can't
            % be precomputed/cached like the transform fitting can).
            if gcTransformSet.method<5
                correctedImage=imwarp(LocalrawImage, gcTransformSet.tformByZ{iZ}, 'Outputview', RA, 'interp', 'nearest'); %nearest, linear or cubic
            else
                % One imwarp call PER BLOCK is what this used to do, and
                % measured on real 901x901 data it was almost entirely
                % imwarp's fixed per-call overhead rather than real pixel
                % work: a call producing just a 4x4 output still cost
                % 2.2ms, so the 25 block calls came to ~32-74ms/slide
                % while the actual resampling is ~5ns/output pixel.
                %
                % Instead, use each block's transform only to work out
                % WHERE to sample (a cheap vectorized point transform),
                % assemble one sample-coordinate grid for the whole
                % output canvas, and resample it all in a SINGLE interp2
                % call -- 3-7x faster depending on method. Coordinates are
                % kept single: it measured the same speed as double and
                % halves the memory, at a worst-case cost of ~0.04% of
                % pixels landing one 0.01 rounding step away from what the
                % per-block imwarp produced.
                %
                % Grid cells no block covers keep coordinate 0, which is
                % outside the image, so interp2's fill value gives them 0
                % -- the same value the old zero-initialized canvas left.
                % The grid depends only on iZ and the fitted transforms,
                % never on image content, so a batch run over several
                % files can reuse it (see gc_SampleGridCache).
                if iZ <= numel(app.gc_SampleGridCache.Xq) && ~isempty(app.gc_SampleGridCache.Xq{iZ})
                    Xq=app.gc_SampleGridCache.Xq{iZ};
                    Yq=app.gc_SampleGridCache.Yq{iZ};
                else
                    mini=gcTransformSet.mini_ImageSize;
                    Xq=zeros(gcTransformSet.outputSize, 'single');
                    Yq=zeros(gcTransformSet.outputSize, 'single');
                    for j=1:gcTransformSet.jL
                        for i=1:gcTransformSet.iL
                            srcPts=transformPointsInverse(gcTransformSet.tformByZ{iZ,j,i}, gcTransformSet.miniPts);
                            xOutput=gcTransformSet.xOutputByBlock{j,i};
                            yOutput=gcTransformSet.yOutputByBlock{j,i};
                            Xq((xOutput(1)+1):xOutput(2), (yOutput(1)+1):yOutput(2))=reshape(single(srcPts(:,1)), mini, mini);
                            Yq((xOutput(1)+1):xOutput(2), (yOutput(1)+1):yOutput(2))=reshape(single(srcPts(:,2)), mini, mini);
                        end
                    end
                    if app.gc_SampleGridCache.stored < app.gc_SampleGridCacheMax && iZ <= numel(app.gc_SampleGridCache.Xq)
                        app.gc_SampleGridCache.Xq{iZ}=Xq;
                        app.gc_SampleGridCache.Yq{iZ}=Yq;
                        app.gc_SampleGridCache.stored = app.gc_SampleGridCache.stored + 1;
                    end
                end
                correctedImage=interp2(LocalrawImage, Xq, Yq, 'cubic', 0);
            end
        end



        function GridSettingStatusChange(app, status)
            %0 - blank state, ready to change settings
            %1 - initilzation and image is loaded, not more setting
            %changes besides average..
            %2 - first plane is done
            %3 - all planes are done, ready for full correction
            app.grid_SettingStatus=status;

            % These four used to be a long list of per-uicontrol Enable=
            % toggles repeated in every case below; now they're pushed to
            % the HTML view model(s) instead (see BuildViewModel/
            % BuildGridEditorViewModel), but the case-by-case
            % GridSetSidebarEnable calls underneath are unchanged.
            app.ui_GridFieldsEnabled = (status==0);
            % Quick Setup is only available from a genuinely blank state --
            % once anything has been set up, it's hard-disabled (not just
            % confirm-guarded) until Reset explicitly puts status back to
            % 0, so it can never accidentally blow away work in progress.
            % "View / Edit Grid" (see ui_ViewEditorEnabled below) is the
            % default action for continuing an already-started grid.
            app.ui_QuickSetupEnabled = (status==0) && ~strcmp(app.filename_GridRef,'none');
            app.ui_ApplyGCEnabled = (status==4);
            app.ui_ViewEditorEnabled = (status>=3); % plane 1 (at least) actually populated by now

            switch(status)
                case 0
                    GridSetSidebarEnable(app, 'populateRest', false);
                    GridSetSidebarEnable(app, 'prev', false);
                    GridSetSidebarEnable(app, 'next', false);
                    GridSetSidebarEnable(app, 'first', false);
                    GridSetSidebarEnable(app, 'last', false);
                    GridSetSidebarEnable(app, 'correctionTest', false);
                    GridSetSidebarEnable(app, 'optimizePlane', false);
                    GridSetSidebarEnable(app, 'adjustOrigin', false);

                case 1
                    GridSetSidebarEnable(app, 'populateRest', false);
                    GridSetSidebarEnable(app, 'prev', false);
                    GridSetSidebarEnable(app, 'next', false);
                    GridSetSidebarEnable(app, 'first', false);
                    GridSetSidebarEnable(app, 'last', false);
                    GridSetSidebarEnable(app, 'correctionTest', false);
                    GridSetSidebarEnable(app, 'optimizePlane', false);
                    GridSetSidebarEnable(app, 'adjustOrigin', false);
                case 2
                    GridSetSidebarEnable(app, 'populateRest', false);
                    GridSetSidebarEnable(app, 'prev', false);
                    GridSetSidebarEnable(app, 'next', false);
                    GridSetSidebarEnable(app, 'first', false);
                    GridSetSidebarEnable(app, 'last', false);
                    GridSetSidebarEnable(app, 'correctionTest', false);
                    GridSetSidebarEnable(app, 'optimizePlane', false);
                    GridSetSidebarEnable(app, 'adjustOrigin', false);
                case 3
                    GridSetSidebarEnable(app, 'populateRest', true);
                    GridSetSidebarEnable(app, 'prev', false);
                    GridSetSidebarEnable(app, 'next', false);
                    GridSetSidebarEnable(app, 'first', false);
                    GridSetSidebarEnable(app, 'last', false);
                    GridSetSidebarEnable(app, 'correctionTest', true);
                    GridSetSidebarEnable(app, 'optimizePlane', true);
                    GridSetSidebarEnable(app, 'adjustOrigin', true);

                case 4
                    GridSetSidebarEnable(app, 'populateRest', true);
                    GridSetSidebarEnable(app, 'prev', true);
                    GridSetSidebarEnable(app, 'next', true);
                    GridSetSidebarEnable(app, 'first', true);
                    GridSetSidebarEnable(app, 'last', true);
                    GridSetSidebarEnable(app, 'correctionTest', true);
                    GridSetSidebarEnable(app, 'optimizePlane', true);
                    GridSetSidebarEnable(app, 'adjustOrigin', true);
            end

            PushViewModel(app);
            PushGridEditorViewModel(app);
        end

        function GridSetSidebarEnable(app, name, value)
            % V6: the nav/action buttons live in GridSidebarUI's HTML now
            % -- just record the flag here (pushed to the page next time
            % PushGridEditorViewModel runs); no uicontrol handle to guard.
            app.ui_GridNav.(name) = logical(value);
        end
        
        function FindGridSpacing(app)
            %get positions and remove the points
            P1=app.grid_Init_Position(1,:);
            P2=app.grid_Init_Position(2,:);
            P3=app.grid_Init_Position(3,:);
            P4=app.grid_Init_Position(4,:);
            
            %sort the points to get 4 corners of a quadrilateral
            Array_1 = [P1;P2;P3;P4];
            order = convhull(Array_1);
            %assert(numel(order) == 5, 'Points do not form a convex quadrilateral');
            orderedpoints = Array_1(order(1:4), :);
            
            %Sort out the order of the corners, top left corner should
            %be first
            center_x=sum(orderedpoints(:,1))/4;
            center_y=sum(orderedpoints(:,2))/4;
            angles=zeros(1,4);
            for index=1:4
                angles(index)=atan2((orderedpoints(index,2)-center_y),(orderedpoints(index,1)-center_x));
                orderedpoints(index,:);
            end
            
            [~,I]=min(angles);
            orderedpoints=circshift(orderedpoints, [1-I 0]);
            
            %Find angle and distance for horizontal and vertical grid points
            pos1=[orderedpoints(1,1) orderedpoints(1,2)];
            pos2=[orderedpoints(2,1) orderedpoints(2,2)];
            [dx, dy]=GridPositionFindOffset(app, pos1, pos2);

            %optimze initial positions....
            pos=[orderedpoints(1,1) orderedpoints(1,2)];

            trial=3;
            while (trial>0)
                trial=trial-1;
                [new_pos, status]=GridPositionOptimize(app, pos, dx, dy);
                pos=new_pos;
                if(status==1)
                    break;
                end
            end

            app.grid_Position(1,:,1)=pos;
            orderedpoints(1,1)=pos(1);
            orderedpoints(1,2)=pos(2);

            pos=[orderedpoints(2,1) orderedpoints(2,2)];
            trial=3;
            while (trial>0)
                trial=trial-1;
                [new_pos, status]=GridPositionOptimize(app, pos, dx, dy);
                pos=new_pos;
                if(status==1)
                    break;
                end
            end
            app.grid_Position(2,:,1)=pos;
            orderedpoints(2,1)=pos(1);
            orderedpoints(2,2)=pos(2);

            pos=[orderedpoints(4,1) orderedpoints(4,2)];
            trial=3;
            while (trial>0)
                trial=trial-1;
                [new_pos, status]=GridPositionOptimize(app, pos, dx, dy);
                pos=new_pos;
                if(status==1)
                    break;
                end
            end
            orderedpoints(4,1)=pos(1);
            orderedpoints(4,2)=pos(2);     
            app.grid_Position(app.grid_SizeX+1,:,1)=pos;
            

            pos1=[orderedpoints(1,1) orderedpoints(1,2)];
            pos2=[orderedpoints(2,1) orderedpoints(2,2)];
            [xdx, xdy]=GridPositionFindOffset(app, pos1, pos2);
            pos2=[orderedpoints(4,1) orderedpoints(4,2)];
            [ydx, ydy]=GridPositionFindOffset(app, pos1, pos2);

            for index=1:app.grid_SizeX*app.grid_SizeY
                for z=1:app.grid_SizeZ
                    app.grid_Info{index,z}.xdx=xdx;
                    app.grid_Info{index,z}.xdy=xdy;
                    app.grid_Info{index,z}.ydx=ydx;
                    app.grid_Info{index,z}.ydy=ydy;
                    app.grid_Info{index,z}.zdx=0;
                    app.grid_Info{index,z}.zdy=0;
                end
            end

            app.grid_Init_Position(1,:)=[orderedpoints(1,1) orderedpoints(1,2)];
            app.grid_Init_Position(2,:)=[orderedpoints(2,1) orderedpoints(2,2)];
            app.grid_Init_Position(3,:)=[orderedpoints(2,1) orderedpoints(4,2)];
            app.grid_Init_Position(4,:)=[orderedpoints(4,1) orderedpoints(4,2)];
            
        end
        
        
        function ChangeRefImagePlane(app)
            if(app.ImgBufReady==false)
                LoadReferenceImage(app);
            end
            app.ref_Image=app.grid_PlaneImgBuf(:,:,app.grid_PlaneCurrent);
            FlattenImage(app);


        end

        %% --- Global-lattice grid detection (replaces neighbor propagation) ---
        %
        % The functions below predict every grid crossing's position from a
        % single global lattice model (spacing/orientation/phase), refine each
        % one INDEPENDENTLY using the existing GridProfile/GridFitting local
        % Gaussian-dip fit, then fit a robust global 2D polynomial surface
        % across all refined points. This means one bad local fit can no
        % longer corrupt its neighbors (the old row/column/plane-to-plane
        % propagation), and the smooth global surface exploits the fact that
        % a real grid varies gradually across the field of view to average
        % out local noise. GridProfile/GridFitting/GridPositionOptimize
        % themselves are reused completely unmodified.

        function [latticeModel, status] = GridAutoDetectLattice(app, refImage)
            % Automatically detect the grid lattice (spacing, orientation and
            % phase) directly from the image via 2D FFT peak-picking plus a
            % projected-profile phase fit -- no manual clicks needed.
            % status: 1 = confident detection, 0 = ambiguous (caller should
            % confirm/nudge), -1 = failed (caller should fall back to manual
            % seeding).

            latticeModel = struct( ...
                'd1',NaN, 'd2',NaN, 'theta1',NaN, 'theta2',NaN, ...
                'u1',[NaN NaN], 'u2',[NaN NaN], 'origin_xy',[NaN NaN], ...
                'originIndex',[ceil(app.grid_SizeX/2) ceil(app.grid_SizeY/2)], ...
                'detectStatus',-1, 'confidence',0);
            status = -1;

            imageData = double(refImage);
            [imgH, imgW] = size(imageData);

            % 1. Auto-crop to the illuminated field
            fieldMask = imageData > 0;
            fieldMask = imclose(fieldMask, strel('disk',15));
            fieldMask = imfill(fieldMask,'holes');
            regionStats = regionprops(fieldMask, 'BoundingBox','Area');
            if isempty(regionStats)
                return;
            end
            [~, biggest] = max([regionStats.Area]);
            bbox = regionStats(biggest).BoundingBox;

            cropCx = bbox(1)+bbox(3)/2;
            cropCy = bbox(2)+bbox(4)/2;
            halfSize = floor(min(bbox(3),bbox(4))*0.42);
            if halfSize < 32
                return; % illuminated field too small to resolve a lattice
            end
            x0 = max(1, round(cropCx-halfSize));
            y0 = max(1, round(cropCy-halfSize));
            x1 = min(imgW, round(cropCx+halfSize)-1);
            y1 = min(imgH, round(cropCy+halfSize)-1);
            crop = imageData(y0:y1, x0:x1);
            N = min(size(crop));
            crop = crop(1:N,1:N);

            % 2. High-pass + windowed 2D FFT magnitude
            blurred = imgaussfilt(crop, 15);
            hp = crop - blurred;
            w = 0.5*(1-cos(2*pi*(0:N-1)/(N-1)));   %manual raised-cosine window
                                                    %(Signal Processing Toolbox's hann is not licensed here)
            win2d = w(:) * w;
            Fmag = abs(fftshift(fft2(hp .* win2d)));
            cy2 = floor(N/2)+1;
            cx2 = floor(N/2)+1;
            [XX,YY] = meshgrid(1:N,1:N);
            Rf = sqrt((XX-cx2).^2+(YY-cy2).^2);
            Fmag(Rf<6) = 0;

            % 3. Greedily pick candidate peaks, keep one of each conjugate pair
            Ftmp = Fmag;
            cand = zeros(0,3);
            for k=1:8
                [peakVal,ind] = max(Ftmp(:));
                if peakVal<=0
                    break;
                end
                [py,px] = ind2sub(size(Ftmp), ind);
                if px-cx2 > 0 || (px-cx2==0 && py-cy2>0)
                    cand(end+1,:) = [px-cx2, py-cy2, peakVal]; %#ok<AGROW>
                end
                Ftmp(max(1,py-5):min(N,py+5), max(1,px-5):min(N,px+5)) = 0;
            end
            if size(cand,1) < 2
                return;
            end

            % 4. Exclude harmonics (|f| ~ 2x a smaller candidate) and keep the
            % two smallest-|f| remaining as the fundamental lattice frequencies
            magf = hypot(cand(:,1), cand(:,2));
            [magf,order] = sort(magf);
            cand = cand(order,:);
            keep = true(size(magf));
            for i=1:numel(magf)
                if ~keep(i), continue; end
                for j=i+1:numel(magf)
                    if ~keep(j), continue; end
                    if abs(magf(j)/magf(i)-2) < 0.15
                        keep(j) = false;
                    end
                end
            end
            cand = cand(keep,:);
            if size(cand,1) < 2
                return;
            end
            f1 = cand(1,1:2);
            f2 = cand(2,1:2);

            d1 = N/hypot(f1(1),f1(2));
            th1 = atan2(f1(2),f1(1));
            d2 = N/hypot(f2(1),f2(2));
            th2 = atan2(f2(2),f2(1));

            % Canonicalize axis labeling & handedness so the same physical
            % direction gets called "axis 1"/"axis 2" from run to run: label
            % the more-horizontal direction as axis 1 (grid X), point it
            % generally rightward, and keep axis 2 within 180deg
            % counter-clockwise of it. This does NOT force exact
            % orthogonality -- the true (possibly non-90-degree) measured
            % angle between the axes is preserved, since that is real
            % distortion signal the later warp needs to correct.
            if abs(cos(th2)) > abs(cos(th1))
                [d1,d2] = deal(d2,d1);
                [th1,th2] = deal(th2,th1);
            end
            if cos(th1) < 0
                th1 = th1 + pi;
            end
            angleDiff = mod(th2-th1, 2*pi);
            if angleDiff > pi
                th2 = th2 + pi;
            end
            u1 = [cos(th1) sin(th1)];
            u2 = [cos(th2) sin(th2)];

            angleBetweenDeg = mod((th2-th1)*180/pi, 180);
            confidence = 1;
            if angleBetweenDeg < 30 || angleBetweenDeg > 150
                confidence = 0; % axes not clearly distinguishable
            end
            if d1 < 8 || d2 < 8 || d1 > N/2 || d2 > N/2
                confidence = 0;
            end

            % 5. Phase/origin: project the raw crop onto each axis and fit the
            % resulting periodic profile with the existing GridFitting model
            [t1_0, okT1] = GridProjectedPhase(app, crop, u1, d1);
            [t2_0, okT2] = GridProjectedPhase(app, crop, u2, d2);
            if ~okT1 || ~okT2
                confidence = min(confidence,0);
            end

            originCrop = [N/2, N/2] + t1_0*u1 + t2_0*u2;
            originFull = originCrop + [x0-1, y0-1];

            latticeModel.d1 = d1;
            latticeModel.d2 = d2;
            latticeModel.theta1 = th1*180/pi;
            latticeModel.theta2 = th2*180/pi;
            latticeModel.u1 = u1;
            latticeModel.u2 = u2;
            latticeModel.origin_xy = originFull;
            latticeModel.confidence = confidence;

            if confidence >= 1
                status = 1;
            else
                status = 0;
            end
            latticeModel.detectStatus = status;
        end

        function [offset, ok] = GridProjectedPhase(app, crop, u, d)
            % Project the crop intensity onto axis direction u and locate
            % the sub-pixel phase of the periodic grid-line dip, reusing
            % the existing GridFitting Gaussian-dip model (temporarily
            % widening its search range to +/- d/2 since this profile
            % spans a full grid period, unlike the narrow local
            % refinement search).
            %
            % The profile is built by FOLDING (synchronously averaging)
            % every period spanned by the crop into one -- not just the
            % single period nearest the crop center. Under weak signal
            % (low counts / low contrast, e.g. a defocused plane), a
            % single-period estimate is noisy enough to occasionally lock
            % onto the WRONG grid line, which then shifts every predicted
            % crossing in the whole plane by a full period -- an error
            % that looks perfectly self-consistent once baked in.
            % Validated on real data: under simulated weak-signal
            % conditions, folding cut the median phase error from ~3px to
            % 0px versus the single-period estimate.
            N = size(crop,1);
            [Xc,Yc] = meshgrid(1:size(crop,2), 1:size(crop,1));
            xr = Xc - N/2;
            yr = Yc - N/2;
            t = xr*u(1) + yr*u(2);
            tFolded = mod(t + d/2, d) - d/2;
            ti = round(tFolded);
            halfWin = floor(d/2);
            tRange = -halfWin:halfWin;
            profile = nan(size(tRange));
            for k=1:numel(tRange)
                m = (ti==tRange(k));
                if any(m(:))
                    profile(k) = mean(crop(m));
                end
            end
            valid = isfinite(profile);
            if nnz(valid) < numel(profile)*0.5
                offset = 0;
                ok = false;
                return;
            end
            profile(~valid) = median(profile(valid));

            savedFitRange = app.fitRange;
            savedDebugPlot = app.debugPlot;
            app.fitRange = max(savedFitRange, halfWin);
            app.debugPlot = false;  % GridFitting's debug plot assumes num is 1 or 2
                                     % (a slot in the local per-point 1x3 subplot
                                     % layout); this whole-profile phase fit doesn't
                                     % belong in that layout, so skip it here.
            [offset, ok, ~] = GridFitting(app, profile, 1);
            app.fitRange = savedFitRange;
            app.debugPlot = savedDebugPlot;
        end

        function latticeModel = GridLatticeFromManualPoints(app)
            % Wrap the legacy manually-clicked 4-corner seeding
            % (grid_Init_Position/FindGridSpacing) into the same
            % latticeModel struct used by the automatic path, so downstream
            % code is agnostic to how the lattice was obtained.
            FindGridSpacing(app);

            pos1 = app.grid_Position(1,:,1);
            pos2 = app.grid_Position(2,:,1);
            posY = app.grid_Position(app.grid_SizeX+1,:,1);

            [xdx, xdy] = GridPositionFindOffset(app, pos1, pos2);
            [ydx, ydy] = GridPositionFindOffset(app, pos1, posY);

            d1 = hypot(xdx,xdy);
            d2 = hypot(ydx,ydy);

            latticeModel.d1 = d1;
            latticeModel.d2 = d2;
            latticeModel.theta1 = atan2(xdy,xdx)*180/pi;
            latticeModel.theta2 = atan2(ydy,ydx)*180/pi;
            latticeModel.u1 = [xdx xdy]/d1;
            latticeModel.u2 = [ydx ydy]/d2;
            latticeModel.origin_xy = pos1;
            latticeModel.originIndex = [1 1];
            latticeModel.detectStatus = 1;
            latticeModel.confidence = 1;
        end

        function ConfirmGridOriginAndRefine(app, plane, latticeModel)
            % Show the CURRENT grid overlay for this plane immediately --
            % no re-optimization up front. This button only runs on a
            % plane that's already been populated (Quick Setup / Populate
            % the rest / a previous adjustment), so app.grid_Position is
            % already a real, refined measurement; forcing a full
            % predict->refine->smooth pass on all 100 points before even
            % showing this would be the slow part, and almost always
            % wasted effort, since confirming/nudging the origin doesn't
            % require redoing work that's already done. Optimization only
            % runs afterward, and only if the drag actually resolves to a
            % real whole-period correction (see GridConfirmOriginClicked).
            %
            % Leave the green point where it is to accept the result.
            % Drag it onto a DIFFERENT real crossing to relabel the
            % origin there (the correction is snapped to the nearest
            % whole lattice period, so the rest of the grid moves with
            % it and re-converges the same way); a small sub-period
            % nudge is a no-op by design -- the point is already sitting
            % on the true crossing to within refinement noise, and
            % GridPositionOptimize's bounded local search would just
            % find that same crossing again.
            %
            % No popup dialog: a separate msgbox window could end up
            % hidden behind the main figure while dragging, which was
            % confusing. Instead, this hides the normal sidebar and
            % temporarily repurposes the "Adjust Grid Origin" button
            % into a "Confirm Origin" button and the instructions box
            % into origin-specific instructions -- same size/position as
            % always, just the one relevant control instead of the full
            % normal set (see GridEnterOriginConfirmMode). This function
            % returns immediately after setup; GridConfirmOriginClicked
            % (wired as that button's Callback) does the actual
            % finalize once the user clicks it, reading back the state
            % stashed in app.grid_PendingOriginConfirm.
            EnterGridEditorMode(app);
            app.ImageCorrectionDialogUIFigure.Name = sprintf('Image Correction Dialog -- Confirm Grid Origin (Plane %d)', plane);
            imshow(app.ref_Image, [0 3], 'Parent', app.GridAxes);
            app.GridAxes.XLim = [0.5, size(app.ref_Image,2)+0.5];
            app.GridAxes.YLim = [0.5, size(app.ref_Image,1)+0.5];

            hold(app.GridAxes, 'on');
            for grid_y = 1:app.grid_SizeY
                for grid_x = 1:app.grid_SizeX
                    index = (grid_y-1)*app.grid_SizeX + grid_x;
                    pos = app.grid_Position(index,:,plane);
                    plot(app.GridAxes, pos(1), pos(2), 'y+', 'MarkerSize', 8, 'LineWidth', 1);
                end
            end
            hold(app.GridAxes, 'off');

            centerIndex = (latticeModel.originIndex(2)-1)*app.grid_SizeX + latticeModel.originIndex(1);
            anchorPos = app.grid_Position(centerIndex,:,plane);
            anchorHandle = drawpoint(app.GridAxes, 'Position', anchorPos, 'Color', [0 1 0]);

            app.grid_PendingOriginConfirm = struct('plane', plane, 'latticeModel', latticeModel, ...
                'anchorHandle', anchorHandle, 'anchorPos', anchorPos);
            GridEnterOriginConfirmMode(app, latticeModel);
        end

        function GridEnterOriginConfirmMode(app, latticeModel)
            % Switches GridSidebarUI into origin-confirm mode: hides the
            % legend and every button except "Confirm Origin" and swaps
            % the instructions text -- via the view model + JS instead of
            % toggling individual annotation/uicontrol Visible/String/
            % Callback, but with the exact same effect (same layout,
            % just the one relevant control instead of the full normal
            % set, so the interface doesn't visually jump around).
            app.ui_GridSidebarMode = 'originConfirm';
            app.ui_GridOriginConfirmInfo = sprintf('Spacing %.1f x %.1fpx, rotation %.1f / %.1fdeg', ...
                latticeModel.d1, latticeModel.d2, latticeModel.theta1, latticeModel.theta2);
            PushGridEditorViewModel(app);
        end

        function GridExitOriginConfirmMode(app)
            % Restore the normal sidebar (reverses GridEnterOriginConfirmMode).
            app.ui_GridSidebarMode = 'normal';
            % Re-sync nav/action enable states -- some may need to stay
            % disabled depending on the current setup status.
            GridSettingStatusChange(app, app.grid_SettingStatus);
        end

        function GridConfirmOriginClicked(app)
            pending = app.grid_PendingOriginConfirm;
            plane = pending.plane;
            latticeModel = pending.latticeModel;
            anchorHandle = pending.anchorHandle;
            anchorPos = pending.anchorPos;

            moved = anchorHandle.Position - anchorPos;
            delete(anchorHandle);

            if hypot(moved(1),moved(2)) > 0.5
                % A raw pixel drag can't be applied directly: every other
                % crossing gets re-seeded from this same origin, and
                % GridPositionOptimize only searches +/-app.fitRange
                % (a few px) around its seed -- far smaller than the
                % lattice spacing. A sub-period nudge just gets pulled
                % right back to the SAME true crossing it started on
                % (the local fit is doing its job), and a nudge that
                % lands between crossings makes every point miss its
                % capture range and fail at once. Either way the drag
                % would silently have no lasting effect.
                %
                % So decompose the drag in lattice-basis coordinates
                % (same math as GridAlignPlanePhase) and snap it to the
                % nearest whole number of periods -- this is what lets a
                % relocation to a different, real crossing actually
                % stick, since every other point then shifts by the same
                % whole-period amount and still lands on its own true
                % neighboring crossing.
                A = [latticeModel.d1*latticeModel.u1(:), latticeModel.d2*latticeModel.u2(:)];
                periodShift = round(A \ moved(:));
                if any(periodShift ~= 0)
                    correction = (A * periodShift)';
                    latticeModel.origin_xy = latticeModel.origin_xy + correction;
                    app.grid_LatticeModel{plane} = latticeModel;
                    GridOptimizePlaneUntilConverged(app, plane, latticeModel, max(app.grid_RefinementPasses,4));
                    GridLog(app, 'Plane %d: origin re-labeled by [%d, %d] whole lattice period(s) (drag was [%.1f, %.1f]px) and re-refined.', ...
                        plane, periodShift(1), periodShift(2), moved(1), moved(2));
                else
                    GridLog(app, ['Plane %d: drag of [%.1f, %.1f]px was less than half a lattice period -- ' ...
                        'the green point was already on the nearest true crossing, so no change was applied.'], ...
                        plane, moved(1), moved(2));
                end
            end

            app.grid_LatticeModel{plane} = latticeModel;
            app.grid_PendingOriginConfirm = [];
            GridExitOriginConfirmMode(app);
            GridChangeDisplayPlane(app); % leave a normal, editable interactive display
        end

        function pos = GridPredictPosition(app, latticeModel, gridX, gridY)
            % Predict a crossing's position purely from the global lattice
            % model -- never from a neighbor's fitted result -- which is
            % what stops one bad local fit from propagating to the rest.
            index = (gridY-1)*app.grid_SizeX + gridX;
            if isfield(latticeModel,'predictedPos')
                pos = latticeModel.predictedPos(index,:);
            else
                pos = latticeModel.origin_xy ...
                    + (gridX-latticeModel.originIndex(1))*latticeModel.d1*latticeModel.u1 ...
                    + (gridY-latticeModel.originIndex(2))*latticeModel.d2*latticeModel.u2;
            end
        end

        function [dx, dy] = GridLatticeLocalSpacing(app, latticeModel, gridX, gridY, dir)
            % Spacing/orientation vector used only to orient the local
            % Gaussian-dip search patch (GridProfile/GridPositionOptimize).
            index = (gridY-1)*app.grid_SizeX + gridX;
            if isfield(latticeModel,'localSpacing')
                v = latticeModel.localSpacing{dir}(index,:);
                dx = v(1);
                dy = v(2);
            elseif dir==1
                dx = latticeModel.d1*latticeModel.u1(1);
                dy = latticeModel.d1*latticeModel.u1(2);
            else
                dx = latticeModel.d2*latticeModel.u2(1);
                dy = latticeModel.d2*latticeModel.u2(2);
            end
        end

        function GridPopulatePlaneAuto(app, plane, latticeModel)
            % Populate every grid crossing on the given plane from the
            % supplied global lattice model, refining each point
            % INDEPENDENTLY (no neighbor-to-neighbor propagation) via the
            % existing GridPositionOptimize/GridProfile/GridFitting local
            % Gaussian-dip fit.
            for grid_y=1:app.grid_SizeY
                for grid_x=1:app.grid_SizeX
                    index=(grid_y-1)*app.grid_SizeX+grid_x;

                    estimatedPos = GridPredictPosition(app, latticeModel, grid_x, grid_y);
                    [xdx, xdy] = GridLatticeLocalSpacing(app, latticeModel, grid_x, grid_y, 1);

                    [newPos, fitStatus, fitQuality] = GridPositionOptimize(app, estimatedPos, xdx, xdy);

                    if fitStatus == 1
                        app.grid_Info{index, plane}.rawPos = newPos;
                        app.grid_Info{index, plane}.fitOK = true;
                    else
                        app.grid_Info{index, plane}.rawPos = estimatedPos;
                        app.grid_Info{index, plane}.fitOK = false;
                        newPos = estimatedPos;
                    end
                    app.grid_Info{index, plane}.fitRMSE = fitQuality;
                    app.grid_Info{index, plane}.source = 'lattice';
                    app.grid_Info{index, plane}.status = double(fitStatus==1);

                    app.grid_Position(index,:,plane) = newPos;
                end
            end
        end

        function [fitStatus, rmseX, rmseY] = GridFitSmoothSurface(app, plane)
            % Fit a robust global 2D polynomial surface X(gridX,gridY),
            % Y(gridX,gridY) across every independently-refined crossing on
            % this plane, then use it as the FINAL position for every
            % point -- this is what lets one bad/noisy local fit be
            % corrected by the rest of the grid instead of propagating.
            fitStatus = 0;
            rmseX = NaN;
            rmseY = NaN;

            nTotal = app.grid_SizeX*app.grid_SizeY;
            gx = zeros(nTotal,1);
            gy = zeros(nTotal,1);
            for grid_y=1:app.grid_SizeY
                for grid_x=1:app.grid_SizeX
                    index=(grid_y-1)*app.grid_SizeX+grid_x;
                    gx(index)=grid_x;
                    gy(index)=grid_y;
                end
            end

            goodMask = false(nTotal,1);
            rawXY = nan(nTotal,2);
            for index=1:nTotal
                info = app.grid_Info{index, plane};
                if isfield(info,'fitOK') && info.fitOK
                    goodMask(index) = true;
                    rawXY(index,:) = info.rawPos;
                end
            end

            nGood = nnz(goodMask);
            if nGood < 6
                return; % not enough points to fit any surface -- leave grid_Position as-is
            end

            goodIdx = find(goodMask);
            [sfX, sfY, surfaceOrder, outlierMaskGood, cvRms] = ...
                GridFitRobustSurface(app, gx(goodIdx), gy(goodIdx), rawXY(goodIdx,:));
            if nGood >= 30
                GridLog(app, ['Plane %d: global surface order selected = %s ' ...
                    '(nPointsUsed=%d, %d excluded as outliers before the decisive fit, ' ...
                    'cross-validated RMS=%.3fpx).'], ...
                    plane, surfaceOrder, nGood, nnz(outlierMaskGood), cvRms);
            end

            predX = sfX(gx,gy);
            predY = sfY(gx,gy);

            for kk=1:numel(goodIdx)
                index = goodIdx(kk);
                r = hypot(rawXY(index,1)-predX(index), rawXY(index,2)-predY(index));
                app.grid_Info{index,plane}.surfaceResidual = r;
                if outlierMaskGood(kk)
                    % Confidently bad (e.g. a local search that "succeeded"
                    % by locking onto noise in a genuinely signal-less
                    % region, such as a vignetted grid corner) -- excluded
                    % from GridFitRobustSurface's decisive fit entirely, not
                    % just down-weighted, so it can't bias the rest of the
                    % plane. Its own final position below still comes from
                    % that clean surface, same as any other point.
                    app.grid_Info{index,plane}.status = 2; %outlier
                else
                    app.grid_Info{index,plane}.status = 1; %good
                end
            end

            for index=1:nTotal
                app.grid_Position(index,:,plane) = [predX(index) predY(index)];
                if ~goodMask(index)
                    app.grid_Info{index,plane}.surfaceResidual = NaN;
                    app.grid_Info{index,plane}.status = 1; %filled in from the smooth trend
                    app.grid_Info{index,plane}.source = 'surface';
                end
            end

            app.grid_SurfaceModel{plane} = struct('sfX',sfX,'sfY',sfY, ...
                'order',surfaceOrder,'nPointsUsed',nGood,'qualityFraction',nGood/nTotal);

            cleanMaskGood = ~outlierMaskGood;
            residX = rawXY(goodIdx(cleanMaskGood),1) - predX(goodIdx(cleanMaskGood));
            residY = rawXY(goodIdx(cleanMaskGood),2) - predY(goodIdx(cleanMaskGood));
            rmseX = sqrt(mean(residX.^2));
            rmseY = sqrt(mean(residY.^2));
            fitStatus = 1;
        end

        function [sfX, sfY, surfaceOrder, outlierMask, cvRms] = GridFitRobustSurface(app, gxGood, gyGood, xyGood)
            % Two-pass robust global surface fit. A point with fitOK=true
            % isn't necessarily real data -- GridPositionOptimize's local
            % search can "succeed" by locking onto noise in a genuinely
            % signal-less region (e.g. a vignetted grid corner well beyond
            % the microscope's illuminated field, confirmed by near-zero
            % local pixel intensity there), and MATLAB's Robust/Bisquare
            % fit option only down-weights such points, it doesn't remove
            % them from influencing the fitted coefficients or (for the
            % >=30-point tier) the cross-validated order choice. So: fit
            % once with every fitOK point to find out which ones disagree
            % with the rest of the plane far more than noise would explain
            % (same MAD-based threshold this function used to only use for
            % the status label), then completely exclude those from a
            % second, decisive fit -- the same clean exclusion already
            % applied to points where the local search failed outright.
            nGood = numel(gxGood);
            warnState = warning('off','curvefit:fit:iterationLimitReached');

            surfaceOrder = GridBaseSurfaceOrder(app, nGood);
            cvRms = NaN;
            if nGood >= 30
                [surfaceOrder, cvRms] = GridSelectSurfaceOrder(app, gxGood, gyGood, xyGood);
            end
            sfX = fit([gxGood gyGood], xyGood(:,1), surfaceOrder, 'Robust','Bisquare');
            sfY = fit([gxGood gyGood], xyGood(:,2), surfaceOrder, 'Robust','Bisquare');

            resid = hypot(xyGood(:,1)-sfX(gxGood,gyGood), xyGood(:,2)-sfY(gxGood,gyGood));
            outlierThresh = max(3, 3*1.4826*mad(resid,1));
            outlierMask = resid > outlierThresh;

            nClean = nGood - nnz(outlierMask);
            % Only trust the exclusion -- and pay for a second fit -- if
            % it actually found a minority of confidently-bad points and
            % enough clean ones remain; a plane where MAD flags close to
            % half its points almost certainly has a different, more
            % fundamental problem (e.g. barely converged at all) that
            % stripping points wouldn't fix, so keep the fuller first fit.
            if any(outlierMask) && nClean >= 6 && nClean >= 0.5*nGood
                gxClean = gxGood(~outlierMask); gyClean = gyGood(~outlierMask); xyClean = xyGood(~outlierMask,:);
                if nClean >= 30
                    [surfaceOrder, cvRms] = GridSelectSurfaceOrder(app, gxClean, gyClean, xyClean);
                else
                    surfaceOrder = GridBaseSurfaceOrder(app, nClean);
                end
                sfX = fit([gxClean gyClean], xyClean(:,1), surfaceOrder, 'Robust','Bisquare');
                sfY = fit([gxClean gyClean], xyClean(:,2), surfaceOrder, 'Robust','Bisquare');
            end
            warning(warnState);
        end

        function surfaceOrder = GridBaseSurfaceOrder(~, nPts)
            % Shared low-point-count floor used both as GridFitRobustSurface's
            % starting order (to run its first outlier-finding pass) and as
            % its final order whenever there aren't enough clean points left
            % to cross-validate reliably.
            if nPts < 15
                surfaceOrder = 'poly11';
            else
                surfaceOrder = 'poly22';
            end
        end

        function [bestOrder, bestRms] = GridSelectSurfaceOrder(~, gxGood, gyGood, rawXYGood)
            % Cross-validated model selection for GridFitSmoothSurface's
            % global polynomial order, in place of a single fixed cap.
            % Try a small ladder of candidate orders and keep whichever
            % one generalizes best to held-out points (5-fold), so a
            % nearly-flat plane stays on a low, noise-resistant order
            % while a heavily distorted plane is allowed the extra
            % flexibility it actually needs -- verified against a real
            % badly-barrel-distorted plane (poly23's held-out RMS ~1.6px
            % vs poly34's ~0.4px there) and against a nearly-flat plane
            % (where jumping straight to poly34 can be mildly worse than
            % poly23, i.e. real overfitting risk if not cross-validated).
            candidateOrders = {'poly22','poly23','poly33','poly34'};
            nPts = numel(gxGood);
            kFold = 5;
            if nPts < kFold*6
                % Not enough points per fold to trust CV -- keep the old
                % fixed behavior rather than risk a noisy order choice.
                bestOrder = 'poly23';
                bestRms = NaN;
                return;
            end

            % Deterministic fold assignment (same points -> same choice
            % every time) without disturbing the global RNG state used
            % elsewhere in the app.
            savedRngState = rng;
            rng(0, 'twister');
            foldOf = mod(randperm(nPts)-1, kFold)' + 1;
            rng(savedRngState);

            warnState = warning('off','curvefit:fit:iterationLimitReached');
            rmsByOrder = inf(numel(candidateOrders),1);
            for k = 1:numel(candidateOrders)
                ord = candidateOrders{k};
                sqErrSum = 0;
                nErr = 0;
                try
                    for f = 1:kFold
                        testMask = foldOf==f;
                        trainMask = ~testMask;
                        sfXcv = fit([gxGood(trainMask) gyGood(trainMask)], rawXYGood(trainMask,1), ord, 'Robust','Bisquare');
                        sfYcv = fit([gxGood(trainMask) gyGood(trainMask)], rawXYGood(trainMask,2), ord, 'Robust','Bisquare');
                        r = hypot(rawXYGood(testMask,1)-sfXcv(gxGood(testMask),gyGood(testMask)), ...
                                  rawXYGood(testMask,2)-sfYcv(gxGood(testMask),gyGood(testMask)));
                        sqErrSum = sqErrSum + sum(r.^2);
                        nErr = nErr + numel(r);
                    end
                    rmsByOrder(k) = sqrt(sqErrSum/nErr);
                catch
                    % Fit failed for this order on this data (e.g. too
                    % few points for its parameter count) -- disqualify
                    % it, keep evaluating the rest.
                end
            end
            warning(warnState);

            % Prefer the simplest order unless a more complex one beats
            % it by a clear (not noise-level) margin -- same style of
            % disagreement-margin safety check GridLatticeFromZHistory
            % uses for its quadratic-vs-local-linear cross-check.
            marginFraction = 0.10;
            bestOrder = candidateOrders{1};
            bestRms = rmsByOrder(1);
            for k = 2:numel(candidateOrders)
                if isfinite(rmsByOrder(k)) && rmsByOrder(k) < bestRms*(1-marginFraction)
                    bestOrder = candidateOrders{k};
                    bestRms = rmsByOrder(k);
                end
            end
        end

        function latticeModel = GridLatticeFromSurface(app, plane)
            % Build a position-dependent local spacing/direction estimate
            % from the fitted surface's local gradient (central finite
            % differences in grid-index space), used to re-seed one extra
            % refinement pass for points near the field edge where the
            % single global lattice model is a poorer local approximation.
            % Still purely a function of the smooth global model, not of
            % any neighbor's raw fit.
            surfaceModel = app.grid_SurfaceModel{plane};

            gx = repmat((1:app.grid_SizeX)', app.grid_SizeY, 1);
            gy = reshape(repmat(1:app.grid_SizeY, app.grid_SizeX, 1), [], 1);

            predX = surfaceModel.sfX(gx, gy);
            predY = surfaceModel.sfY(gx, gy);

            dx1 = (surfaceModel.sfX(gx+1,gy) - surfaceModel.sfX(gx-1,gy))/2;
            dy1 = (surfaceModel.sfY(gx+1,gy) - surfaceModel.sfY(gx-1,gy))/2;
            dx2 = (surfaceModel.sfX(gx,gy+1) - surfaceModel.sfX(gx,gy-1))/2;
            dy2 = (surfaceModel.sfY(gx,gy+1) - surfaceModel.sfY(gx,gy-1))/2;

            latticeModel = app.grid_LatticeModel{plane};
            latticeModel.predictedPos = [predX predY];
            latticeModel.localSpacing = {[dx1 dy1], [dx2 dy2]};
        end

        function [ok, spacingChange1, spacingChange2, angleChange1, angleChange2] = ...
                GridLatticeContinuityOk(~, modelA, modelB)
            % Shared threshold check: is modelB a physically-plausible
            % single smooth step away from modelA (5% spacing / 2deg
            % angle)? Used both by GridCheckPlaneContinuity (logging
            % only) and by GridSeedPlaneLattice's bridging trigger
            % (actually gates behavior there).
            spacingChange1 = abs(modelB.d1-modelA.d1)/modelA.d1;
            spacingChange2 = abs(modelB.d2-modelA.d2)/modelA.d2;
            angleChange1 = abs(modelB.theta1-modelA.theta1);
            angleChange2 = abs(modelB.theta2-modelA.theta2);
            ok = spacingChange1<=0.05 && spacingChange2<=0.05 && angleChange1<=2 && angleChange2<=2;
        end

        function GridCheckPlaneContinuity(app, plane)
            % Non-blocking sanity check (NOT a propagation dependency):
            % warn if this plane's detected lattice differs sharply from
            % the previous plane's, since the physical grid should drift
            % only gradually across an eV/focus series. Purely
            % informational now that GridSeedPlaneLattice actively traces
            % the lattice across Z and bridges large jumps -- this should
            % rarely fire in practice.
            if plane < 2 || numel(app.grid_LatticeModel) < plane ...
                    || isempty(app.grid_LatticeModel{plane-1}) || isempty(app.grid_LatticeModel{plane})
                return;
            end
            prevModel = app.grid_LatticeModel{plane-1};
            curModel = app.grid_LatticeModel{plane};

            [ok, spacingChange1, spacingChange2, angleChange1, angleChange2] = ...
                GridLatticeContinuityOk(app, prevModel, curModel);

            if ~ok
                GridLog(app, ['Plane %d: detected lattice differs notably from plane %d ' ...
                     '(spacing change %.1f%%/%.1f%%, angle change %.1f/%.1fdeg). ' ...
                     'Consider visually re-checking this plane.'], ...
                    plane, plane-1, spacingChange1*100, spacingChange2*100, angleChange1, angleChange2);
            end
        end

        function GridUpdatePlaneTrust(app, plane)
            % Decide whether this plane's own accepted lattice model
            % should be allowed to feed the Z-trend/per-point-history
            % fits that later planes (and GridFitZSmoothing) rely on --
            % decoupled from GridAutoDetectLattice's own raw `confidence`
            % flag, which sanity-checks internal consistency only and can
            % still be confidently wrong (see plane 8 in the real
            % 8-plane test stack: a weak spurious FFT peak beat the true
            % second lattice peak, producing a `confidence=1` result that
            % was actually badly tilted).
            %
            % Trust here rests on point-level convergence alone
            % (qualityFraction >= 0.5, same bar GridFitZSmoothing/
            % GridLatticeFromZHistory already use) -- consistency with the
            % Z-trend itself is already enforced upstream, by
            % GridSeedPlaneLattice's own acceptance gate for a
            % 'trend'/'trend+Nprobes' source (checking a candidate against
            % its own trend here would be circular), and by that
            % function's caller explicitly forcing `trusted=false` for a
            % 'fft-*' (bridging-exhausted/last-resort) source regardless
            % of quality, since such a plane is already known to disagree
            % with its own history.
            if numel(app.grid_LatticeModel) < plane || isempty(app.grid_LatticeModel{plane})
                return;
            end
            qualityFraction = 0;
            if numel(app.grid_SurfaceModel) >= plane && ~isempty(app.grid_SurfaceModel{plane}) ...
                    && isfield(app.grid_SurfaceModel{plane},'qualityFraction')
                qualityFraction = app.grid_SurfaceModel{plane}.qualityFraction;
            end
            app.grid_LatticeModel{plane}.trusted = qualityFraction >= 0.5;
        end

        %% --- V7: trace lattice parameters across Z instead of re-detecting via FFT per plane ---
        %
        % GridAutoDetectLattice's FFT peak-picking ranks candidate lattice
        % frequencies by magnitude only, never by peak strength -- so it
        % can pick a real but weak spurious peak over the true (stronger)
        % lattice peak and still report high confidence (found on the real
        % 8-plane test stack: plane 8's d2/theta2 came from a ~5x-weaker
        % peak than the true axis, producing a badly tilted, "confidently
        % wrong" lattice). Since the physical grid's spacing/orientation
        % drift smoothly and slowly across a real Z series, planes beside
        % plane 1 should get their seed by TRACING that smooth trend from
        % already-trusted planes, falling back to a fresh FFT reading only
        % as a last resort -- see GridSeedPlaneLattice below.

        function [trendModel, ok] = GridLatticeTrendPredict(app, samples, queryZ)
            % Evaluate the robust Z-trend (see GridLatticeTrendFit) AT a
            % specific z. Kept as a thin wrapper around GridLatticeTrendFit
            % so there is exactly one trend-fitting implementation; this
            % one actually queries the fitted curves at queryZ instead of
            % at the samples' own mean.
            trendModel = struct('d1',NaN,'d2',NaN,'theta1',NaN,'theta2',NaN, ...
                'u1',[NaN NaN],'u2',[NaN NaN],'origin_xy',[NaN NaN], ...
                'originIndex',[ceil(app.grid_SizeX/2) ceil(app.grid_SizeY/2)], ...
                'detectStatus',1,'confidence',1,'trusted',false,'source','trend');
            ok = false;
            if isempty(samples)
                return;
            end
            samples = sortrows(samples,1);
            n = size(samples,1);
            if n == 1
                trendModel.d1 = samples(1,2); trendModel.d2 = samples(1,3);
                trendModel.theta1 = samples(1,4); trendModel.theta2 = samples(1,5);
                trendModel.origin_xy = samples(1,6:7);
            else
                zOrder = 'poly1';
                if n >= 6
                    zOrder = 'poly2';
                end
                warnState = warning('off','curvefit:fit:iterationLimitReached');
                sfD1 = fit(samples(:,1), samples(:,2), zOrder, 'Robust','Bisquare');
                sfD2 = fit(samples(:,1), samples(:,3), zOrder, 'Robust','Bisquare');
                sfT1 = fit(samples(:,1), samples(:,4), zOrder, 'Robust','Bisquare');
                sfT2 = fit(samples(:,1), samples(:,5), zOrder, 'Robust','Bisquare');
                sfOx = fit(samples(:,1), samples(:,6), zOrder, 'Robust','Bisquare');
                sfOy = fit(samples(:,1), samples(:,7), zOrder, 'Robust','Bisquare');
                warning(warnState);
                trendModel.d1 = sfD1(queryZ); trendModel.d2 = sfD2(queryZ);
                trendModel.theta1 = sfT1(queryZ); trendModel.theta2 = sfT2(queryZ);
                trendModel.origin_xy = [sfOx(queryZ) sfOy(queryZ)];
            end
            trendModel.u1 = [cosd(trendModel.theta1) sind(trendModel.theta1)];
            trendModel.u2 = [cosd(trendModel.theta2) sind(trendModel.theta2)];
            ok = true;
        end

        function [latticeModel, status] = GridProbeIntermediateLattice(app, approxZ)
            % Disposable lattice-parameter sample at a FRACTIONAL plane
            % index, bridging a gap that looks too large to trace
            % directly. Reads and sums app.grid_PlaneAveraging RAW slides
            % (same count as a real plane -- never a smaller/noisier
            % average) starting at the slide number that fractional plane
            % index maps to, applies the same flatfield gain + intensity
            % clamp every plane gets, then runs the existing
            % GridAutoDetectLattice on it. Touches nothing persistent
            % (grid_PlaneImgBuf/grid_Position/grid_Info are untouched) --
            % purely scaffolding for GridLatticeTrendPredict, forgotten as
            % soon as the target plane is done.
            latticeModel = [];
            status = -1;
            firstSlideNum = round(app.grid_PlaneStart + (approxZ-1)*app.grid_PlaneInterval) + 1;
            maxSlide = app.grid_PlaneStart + (app.grid_SizeZ-1)*app.grid_PlaneInterval + app.grid_PlaneAveraging;
            if firstSlideNum < 1 || firstSlideNum + app.grid_PlaneAveraging - 1 > maxSlide
                return;
            end
            try
                tiffReader = Tiff(app.filename_GridRef, 'r');
                cleanupTiffReader = onCleanup(@() close(tiffReader));
                tiffReader.setDirectory(firstSlideNum);
                accum = double(tiffReader.read());
                for k = 2:app.grid_PlaneAveraging
                    tiffReader.setDirectory(firstSlideNum + k - 1);
                    accum = accum + double(tiffReader.read());
                end
            catch
                return;
            end
            [FFGain, ffOK] = GridLoadFlatfieldGainMap(app);
            if ffOK
                accum = accum .* FFGain;
            end
            accum(accum>3) = 3; % same clamp FlattenImage applies
            [latticeModel, status] = GridAutoDetectLattice(app, accum);
        end

        function [qualityFraction, selfModel, selfOk] = GridTrySeedAndCheck(app, plane, seedCandidate, qualityFloor, lightPasses)
            % Shared "try one candidate" step used at every tier of
            % GridSeedPlaneLattice below: seed this plane's per-point
            % positions from seedCandidate (still via GridLatticeFromZHistory,
            % so each point's own trusted Z-history still wins where it
            % exists), run the "light" optimization pass, and report the
            % resulting point-level quality. When quality clears the
            % floor, also re-derive this plane's OWN lattice model
            % directly from its newly-converged points
            % (GridLatticeFromConvergedPoints) -- once real, locally-
            % refined measurements exist, they're a more trustworthy
            % characterization of the plane's true geometry than the seed
            % candidate that merely got refinement started.
            %
            % lightPasses is >1 (not just a single pass) deliberately:
            % every plane still gets a full THOROUGH multi-pass refinement
            % later (after Z-correlation, in PopulatetherestButtonPushed),
            % but THIS pass's result is also what every LATER plane's own
            % per-point Z-history seeds from during the very same
            % populate-the-rest loop (the thorough pass for plane i
            % doesn't run until after planes i+1..N have already used
            % plane i's light-pass-only positions as history) -- so a
            % weak light pass on an early plane quietly hands worse
            % history forward to every plane after it. Cost stays bounded
            % regardless of lightPasses, since
            % GridOptimizePlaneUntilConverged already stops as soon as a
            % pass stops improving.
            seedModel = GridLatticeFromZHistory(app, plane, seedCandidate);
            % GridOptimizePlaneUntilConverged's pass>1 reseeds via
            % GridLatticeFromSurface, which reads app.grid_LatticeModel{plane}
            % -- normally set by GridSeedPlaneLattice's own caller, but
            % only AFTER it returns, so with lightPasses>1 this trial
            % needs a value staged there itself. Harmless to overwrite
            % here: whichever candidate this call ultimately accepts (or
            % doesn't) is exactly what the caller sets there for real once
            % GridSeedPlaneLattice returns, so a mid-trial value here is
            % never relied on by anything outside this function.
            app.grid_LatticeModel{plane} = seedCandidate;
            GridOptimizePlaneUntilConverged(app, plane, seedModel, lightPasses);
            qualityFraction = 0;
            if numel(app.grid_SurfaceModel) >= plane && ~isempty(app.grid_SurfaceModel{plane}) ...
                    && isfield(app.grid_SurfaceModel{plane},'qualityFraction')
                qualityFraction = app.grid_SurfaceModel{plane}.qualityFraction;
            end
            selfModel = [];
            selfOk = false;
            if qualityFraction >= qualityFloor
                [selfModel, selfOk] = GridLatticeFromConvergedPoints(app, plane);
            end
        end

        function entry = GridSeedHistoryEntry(app, plane, stage, bridgeDepth, candidate, ...
                qualityFraction, probeZ, probeModel, probeStatus)
            % Builds one GridLastSeedHistory row -- factored out since
            % GridSeedPlaneLattice below records one at every tier
            % (trend / fft-reset / bridge).
            goodMask = false(app.grid_SizeX*app.grid_SizeY,1);
            rawXY = nan(app.grid_SizeX*app.grid_SizeY,2);
            for idx = 1:numel(goodMask)
                info = app.grid_Info{idx,plane};
                goodMask(idx) = isstruct(info) && isfield(info,'fitOK') && info.fitOK;
                if goodMask(idx)
                    rawXY(idx,:) = info.rawPos;
                end
            end
            gx = repmat((1:app.grid_SizeX)', app.grid_SizeY, 1);
            gy = reshape(repmat(1:app.grid_SizeY, app.grid_SizeX, 1), [], 1);
            % Deliberately on the RAW, pre-smoothing fitted positions
            % (grid_Info.rawPos), not app.grid_Position -- see
            % GridSeedPlaneLattice's header comment on why surfResid is
            % diagnostic-only here, never a gate.
            surfResid = GridSurfaceResidualRMS(app, gx, gy, rawXY, goodMask);
            entry = struct('stage',stage, 'bridgeDepth',bridgeDepth, 'candidate',candidate, ...
                'pos',app.grid_Position(:,:,plane), 'ok',goodMask, ...
                'qualityFraction',qualityFraction, 'surfResid',surfResid, ...
                'probeZ',probeZ, 'probeModel',probeModel, 'probeStatus',probeStatus);
        end

        function [latticeModel, source] = GridSeedPlaneLattice(app, plane)
            % Primary per-plane lattice seed for plane>=2, three tiers
            % tried in order (cheapest/most-trusted first):
            %
            % 1. TREND -- extrapolate d1/d2/theta1/theta2/origin from
            %    already-trusted planes' smooth Z-evolution
            %    (GridLatticeTrendPredict). No comparison against a fresh
            %    FFT reading at all: measured live, a plane's own FFT
            %    detection disagreeing by a few percent from the trend is
            %    routine noise, not evidence of a problem -- gating
            %    acceptance on that agreement (an earlier version of this
            %    function did) made bridging fire on nearly every plane
            %    for no real benefit, while contributing nothing towards
            %    catching a genuine failure (quality was already fine on
            %    every one of those routine cases).
            % 2. FFT HARD RESET -- only reached if tier 1's quality comes
            %    out LOW (below qualityFloor): that's the actual signal
            %    something is wrong (a bad seed, or genuine loss of
            %    periodicity), so re-detect this plane's lattice from
            %    scratch via GridAutoDetectLattice and retry.
            % 3. BRIDGING -- only reached if tier 2 ALSO comes out low (or
            %    FFT itself fails to detect anything): insert a disposable
            %    probe sample (GridProbeIntermediateLattice) at the
            %    Z-midpoint back to the last trusted plane, extend the
            %    trend with it, and retry -- bisecting up to 4 probes or
            %    until the remaining gap is smaller than one averaging
            %    window, then falling back to the plane's own fresh FFT
            %    reading (or the previous plane's model) as the true last
            %    resort.
            %
            % At every tier, once quality clears qualityFloor, the plane's
            % ACCEPTED lattice model is re-derived directly from its own
            % newly-converged points (GridLatticeFromConvergedPoints) --
            % see GridTrySeedAndCheck -- rather than just keeping whatever
            % seed candidate happened to start that tier's refinement.
            % Real, locally-refined measurements are more trustworthy than
            % any seed once enough of them exist.
            maxBridgeDepth = 4;
            qualityFloor = 0.5;
            % Deliberately >1: see GridTrySeedAndCheck's header comment on
            % why the light pass benefits from more than a single
            % iteration, bounded by GridOptimizePlaneUntilConverged's own
            % stop-when-no-longer-improving check.
            lightPasses = 3;

            trustedSamples = zeros(0,7);
            lastTrustedZ = NaN;
            for z = 1:plane-1
                if numel(app.grid_LatticeModel) >= z && ~isempty(app.grid_LatticeModel{z}) ...
                        && isfield(app.grid_LatticeModel{z},'trusted') && app.grid_LatticeModel{z}.trusted
                    m = app.grid_LatticeModel{z};
                    trustedSamples(end+1,:) = [z, m.d1, m.d2, m.theta1, m.theta2, m.origin_xy]; %#ok<AGROW>
                    lastTrustedZ = z;
                end
            end

            history = struct('stage',{}, 'bridgeDepth',{}, 'candidate',{}, 'pos',{}, 'ok',{}, ...
                'qualityFraction',{}, 'surfResid',{}, 'probeZ',{}, 'probeModel',{}, 'probeStatus',{});

            % --- Tier 1: trend (skipped only if there's no trusted history at all yet) ---
            if ~isempty(trustedSamples)
                [candidate, ~] = GridLatticeTrendPredict(app, trustedSamples, plane);
                [qualityFraction, selfModel, selfOk] = GridTrySeedAndCheck(app, plane, candidate, qualityFloor, lightPasses);
                history(end+1) = GridSeedHistoryEntry(app, plane, 'trend', 0, candidate, qualityFraction, NaN, [], NaN);

                if qualityFraction >= qualityFloor
                    app.GridLastSeedHistory{plane} = history;
                    if selfOk
                        latticeModel = GridAlignPlanePhase(app, plane, selfModel);
                        source = 'trend+self-consistent';
                    else
                        latticeModel = GridAlignPlanePhase(app, plane, candidate);
                        source = 'trend';
                    end
                    return;
                end
                GridLog(app, 'Plane %d: trend-seeded quality low (%.0f%%) -- hard-resetting via fresh FFT detection.', ...
                    plane, 100*qualityFraction);
            end

            % --- Tier 2: FFT hard reset ---
            [fftModel, fftStatus] = GridAutoDetectLattice(app, app.ref_Image);
            if fftStatus >= 0
                [qualityFraction, selfModel, selfOk] = GridTrySeedAndCheck(app, plane, fftModel, qualityFloor, lightPasses);
                history(end+1) = GridSeedHistoryEntry(app, plane, 'fft-reset', 0, fftModel, qualityFraction, NaN, [], NaN);

                if qualityFraction >= qualityFloor
                    app.GridLastSeedHistory{plane} = history;
                    if selfOk
                        latticeModel = GridAlignPlanePhase(app, plane, selfModel);
                        source = 'fft-reset+self-consistent';
                    else
                        latticeModel = GridAlignPlanePhase(app, plane, fftModel);
                        source = 'fft-reset';
                    end
                    return;
                end
                GridLog(app, 'Plane %d: fresh FFT detection ALSO gave low quality (%.0f%%).', plane, 100*qualityFraction);
            end

            if isempty(trustedSamples)
                % Nothing to bridge from (shouldn't normally happen past
                % plane 1) -- accept whatever the FFT hard-reset gave, or
                % the previous plane's model if even FFT failed outright.
                app.GridLastSeedHistory{plane} = history;
                if fftStatus >= 0
                    latticeModel = GridAlignPlanePhase(app, plane, fftModel);
                    source = 'unresolved-low-quality';
                else
                    latticeModel = app.grid_LatticeModel{plane-1};
                    source = 'unresolved-reuse-previous';
                end
                return;
            end

            % --- Tier 3: bridging (reserved for genuinely hard planes now) ---
            bridgeDepth = 0;
            while true
                remainingGapSlides = (plane - lastTrustedZ) * app.grid_PlaneInterval;
                if bridgeDepth >= maxBridgeDepth || remainingGapSlides <= app.grid_PlaneAveraging
                    % Bridging exhausted (or the remaining gap is already
                    % too small to usefully subdivide) -- fall back to the
                    % fresh FFT reading if it detected anything at all,
                    % else reuse the previous plane's model.
                    app.GridLastSeedHistory{plane} = history;
                    if fftStatus >= 0
                        latticeModel = GridAlignPlanePhase(app, plane, fftModel);
                        source = 'unresolved-last-resort';
                    else
                        latticeModel = app.grid_LatticeModel{plane-1};
                        source = 'unresolved-reuse-previous';
                    end
                    GridLog(app, ['Plane %d: bridging exhausted after %d probe(s); ' ...
                        'falling back to %s.'], plane, bridgeDepth, source);
                    return;
                end

                midZ = (lastTrustedZ + plane)/2;
                [probeModel, probeStatus] = GridProbeIntermediateLattice(app, midZ);
                bridgeDepth = bridgeDepth + 1;
                if probeStatus >= 0
                    trustedSamples(end+1,:) = [midZ, probeModel.d1, probeModel.d2, ...
                        probeModel.theta1, probeModel.theta2, probeModel.origin_xy]; %#ok<AGROW>
                    lastTrustedZ = midZ;
                    GridLog(app, 'Plane %d: bridging probe #%d at z=%.2f (d1=%.2f d2=%.2f, rotation %.1f/%.1fdeg).', ...
                        plane, bridgeDepth, midZ, probeModel.d1, probeModel.d2, probeModel.theta1, probeModel.theta2);
                end
                % If the probe itself failed to detect anything, the loop
                % just retries with the SAME trustedSamples/lastTrustedZ --
                % bridgeDepth still advances, so this can't loop forever.

                [candidate, ~] = GridLatticeTrendPredict(app, trustedSamples, plane);
                [qualityFraction, selfModel, selfOk] = GridTrySeedAndCheck(app, plane, candidate, qualityFloor, lightPasses);
                history(end+1) = GridSeedHistoryEntry(app, plane, 'bridge', bridgeDepth, candidate, ...
                    qualityFraction, midZ, probeModel, probeStatus); %#ok<AGROW>

                if qualityFraction >= qualityFloor
                    app.GridLastSeedHistory{plane} = history;
                    if selfOk
                        latticeModel = GridAlignPlanePhase(app, plane, selfModel);
                        source = sprintf('trend+%dprobe(s)+self-consistent', bridgeDepth);
                    else
                        latticeModel = GridAlignPlanePhase(app, plane, candidate);
                        source = sprintf('trend+%dprobe(s)', bridgeDepth);
                    end
                    return;
                end
            end
        end

        function [latticeModel, ok] = GridLatticeFromConvergedPoints(app, plane)
            % Re-derive this plane's OWN global d1/d2/theta1/theta2/origin
            % directly from its own converged crossings' measured raw
            % positions, via a simple linear (poly11) fit of position vs.
            % grid index -- once a plane has enough real, locally-refined
            % measurements, this is a more trustworthy characterization of
            % "the plane's actual lattice" than either FFT peak-picking on
            % the raw image (can lock onto a real-but-spurious peak, as
            % happened on plane 8 in the real test stack) or continuing to
            % lean on a seed candidate that merely got refinement started.
            %
            % Deliberately poly11 (not the higher-order poly22/poly23
            % GridFitSmoothSurface uses for grid_Position itself, whose
            % curvature terms capture real per-point distortion) -- this
            % function is only after the single GLOBAL d1/d2/theta a plane
            % is characterized by; per-point distortion on top of that is
            % a separate concern GridLatticeFromSurface's local gradient
            % already handles downstream.
            latticeModel = [];
            ok = false;

            nTotal = app.grid_SizeX*app.grid_SizeY;
            gx = zeros(nTotal,1);
            gy = zeros(nTotal,1);
            for grid_y=1:app.grid_SizeY
                for grid_x=1:app.grid_SizeX
                    index=(grid_y-1)*app.grid_SizeX+grid_x;
                    gx(index)=grid_x;
                    gy(index)=grid_y;
                end
            end

            goodMask = false(nTotal,1);
            rawXY = nan(nTotal,2);
            for index=1:nTotal
                info = app.grid_Info{index, plane};
                if isstruct(info) && isfield(info,'fitOK') && info.fitOK
                    goodMask(index) = true;
                    rawXY(index,:) = info.rawPos;
                end
            end
            if nnz(goodMask) < 6
                return;
            end

            warnState = warning('off','curvefit:fit:iterationLimitReached');
            sfX = fit([gx(goodMask) gy(goodMask)], rawXY(goodMask,1), 'poly11', 'Robust','Bisquare');
            sfY = fit([gx(goodMask) gy(goodMask)], rawXY(goodMask,2), 'poly11', 'Robust','Bisquare');
            warning(warnState);

            v1 = [sfX.p10 sfY.p10]; % d(position)/d(gridX)
            v2 = [sfX.p01 sfY.p01]; % d(position)/d(gridY)
            d1 = norm(v1);
            d2 = norm(v2);
            if ~isfinite(d1) || ~isfinite(d2) || d1 < 8 || d2 < 8
                return; % degenerate fit -- not enough spread/too few points to trust
            end
            u1 = v1/d1;
            u2 = v2/d2;

            originIndex = [ceil(app.grid_SizeX/2) ceil(app.grid_SizeY/2)];
            origin_xy = [sfX(originIndex(1),originIndex(2)) sfY(originIndex(1),originIndex(2))];

            latticeModel = struct('d1',d1, 'd2',d2, ...
                'theta1',atan2d(u1(2),u1(1)), 'theta2',atan2d(u2(2),u2(1)), ...
                'u1',u1, 'u2',u2, 'origin_xy',origin_xy, 'originIndex',originIndex, ...
                'detectStatus',1, 'confidence',1);
            ok = true;
        end

        %% --- V7: sub-plane drift correction (run only once every plane is trusted) ---

        function [correctedImage, meanDriftPx, nRejected] = GridEstimatePlaneDrift(app, plane)
            % Re-reads the raw sub-slides that make up this plane's
            % average and rigidly registers each to the window's first
            % sub-slide (phase-correlation via imregcorr) before summing,
            % instead of LoadReferenceImage's naive direct sum -- corrects
            % for stage/beam drift across the averaging window, sharpening
            % the plane image before refitting. Deliberately only run on
            % demand, after every plane is already trusted (grid_SettingStatus==4):
            % re-reading every raw sub-slide for every plane is the slow
            % part, and there's no point sharpening a plane whose grid
            % position isn't trusted yet anyway.
            %
            % The image being registered is a periodic grid shadow --
            % exactly the pattern generic phase-correlation registration
            % is weakest against, since a shift of a whole lattice period
            % looks nearly as good a match as the true (much smaller)
            % sub-plane drift. Confirmed empirically: on real data, a
            % handful of this dataset's planes returned "drift" of
            % 27-31px, suspiciously close to this dataset's own ~37-41px
            % lattice spacing -- a textbook period-aliased registration,
            % not real drift. Any estimate above maxPlausibleDriftPx is
            % therefore rejected outright (that slide falls back to
            % unaligned rather than being shifted by a wrong, wild
            % amount) rather than trusted just because imregcorr returned
            % *something*.
            maxPlausibleDriftPx = 8;

            filename = app.filename_GridRef;
            tiffReader = Tiff(filename, 'r');
            cleanupTiffReader = onCleanup(@() close(tiffReader));

            firstSlideNum = GridPlaneSlideNumber(app, plane) + 1;
            tiffReader.setDirectory(firstSlideNum);
            fixedSlide = double(tiffReader.read());

            accum = fixedSlide;
            driftMags = nan(1, app.grid_PlaneAveraging-1);
            nRejected = 0;
            for k = 2:app.grid_PlaneAveraging
                tiffReader.setDirectory(firstSlideNum + k - 1);
                movingSlide = double(tiffReader.read());
                alignedSlide = movingSlide; % default: unaligned, if registration fails or looks implausible
                try
                    tform = imregcorr(movingSlide, fixedSlide, "translation");
                    driftMag = hypot(tform.Translation(1), tform.Translation(2));
                    if driftMag <= maxPlausibleDriftPx
                        alignedSlide = imwarp(movingSlide, tform, 'OutputView', imref2d(size(fixedSlide)), 'FillValues', 0);
                        driftMags(k-1) = driftMag;
                    else
                        nRejected = nRejected + 1; % likely period-aliased, not real drift -- discard
                    end
                catch
                    nRejected = nRejected + 1;
                end
                accum = accum + alignedSlide;
            end

            correctedImage = accum;
            meanDriftPx = mean(driftMags, 'omitnan');
        end

        function GridRefineAllPlanes(app)
            % Only meaningful once every plane is already populated and
            % trusted. Two stages: (1) re-sharpen every plane's image via
            % GridEstimatePlaneDrift's sub-slide registration, (2) rerun
            % the SAME cross-plane Z-correlation + thorough multi-pass
            % refinement sequence PopulatetherestButtonPushed's own tail
            % already runs -- a full redo of the post-processing over the
            % now-sharper images, not just a one-shot per-point touch-up.
            % (An earlier version of this function only did a single-shot
            % regressive-safe GridPositionOptimize per point here; that
            % never gave a drift-corrected plane the chance to have its
            % OWN outliers caught/replaced by the cross-plane trend, or
            % scattered points pulled back onto a consistent surface --
            % exactly what Z-correlation + the thorough pass already do
            % for the initial population.)
            if app.grid_SettingStatus < 4
                uialert(app.ImageCorrectionDialogUIFigure, ...
                    'Refine All Planes needs every plane to be populated first (Populate the Rest must finish).', ...
                    'Not Ready');
                return;
            end

            fig = app.ImageCorrectionDialogUIFigure;
            dlg = uiprogressdlg(fig, 'Title', 'Refining All Planes', 'Cancelable','on');

            [FFGain, ffOK] = GridLoadFlatfieldGainMap(app);

            % --- Stage 1: sub-plane drift correction (unchanged) ---
            for plane = 1:app.grid_SizeZ
                dlg.Value = 0.5*plane/app.grid_SizeZ;
                dlg.Message = sprintf('Plane %d/%d: estimating sub-plane drift...', plane, app.grid_SizeZ);

                [correctedImage, meanDriftPx, nRejected] = GridEstimatePlaneDrift(app, plane);
                if ffOK
                    correctedImage = correctedImage .* FFGain;
                end
                app.grid_PlaneImgBuf(:,:,plane) = correctedImage;
                if nRejected > 0
                    GridLog(app, ['Plane %d/%d: mean sub-slide drift %.2fpx (%d/%d slide(s) rejected as ' ...
                        'implausible/likely period-aliased and left unaligned)'], ...
                        plane, app.grid_SizeZ, meanDriftPx, nRejected, app.grid_PlaneAveraging-1);
                else
                    GridLog(app, 'Plane %d/%d: mean sub-slide drift %.2fpx', plane, app.grid_SizeZ, meanDriftPx);
                end
                if dlg.CancelRequested
                    close(dlg);
                    GridChangeDisplayPlane(app);
                    return;
                end
            end

            % --- Stage 2: Z-correlation + thorough per-plane refinement,
            % mirroring PopulatetherestButtonPushed's tail exactly ---
            GridLog(app, 'Correlating grid positions across planes (Z)...');
            GridFitZSmoothing(app);
            GridLog(app, 'Z-correlation done.');

            for plane = 1:app.grid_SizeZ
                dlg.Value = 0.5 + 0.5*plane/app.grid_SizeZ;
                dlg.Message = sprintf('Refining plane %d / %d (post-drift-correction)', plane, app.grid_SizeZ);
                planeTimer = tic;
                app.grid_PlaneCurrent = plane;
                ChangeRefImagePlane(app); % app.ref_Image = grid_PlaneImgBuf(:,:,plane) (now drift-corrected) + FlattenImage
                seedModel = GridLatticeFromCurrentPositions(app, plane);
                GridOptimizePlaneUntilConverged(app, plane, seedModel, max(app.grid_RefinementPasses,4));
                GridUpdatePlaneTrust(app, plane);
                GridLog(app, 'Plane %d/%d: refine done in %.2fs', plane, app.grid_SizeZ, toc(planeTimer));
                if dlg.CancelRequested
                    break
                end
            end

            close(dlg);
            GridChangeDisplayPlane(app); % refresh whichever plane is currently shown
        end

        function GridVerifyOverallCorrection(app)
            % Grid-corrects just the reference stack's grid planes IN
            % MEMORY and shows the before/after intensity cross-sections
            % built from them.
            %
            % An earlier version tried to also re-run detection on the
            % corrected image inline, in this same live app instance, to
            % fully automate the before/after comparison in one click.
            % That repeatedly hung intermittently for reasons not pinned
            % down (a fresh, separate app instance running the identical
            % Quick Setup + Populate the Rest sequence as a plain script
            % never had this problem) -- rather than ship a re-detection
            % path with a known but unexplained hang risk, this verifies
            % from pixel data alone (GridShowIntensityCrossSections),
            % which needs no detection at all.
            %
            % It also used to write a fully corrected copy of the whole
            % input stack to a temp file and read it back. Nothing
            % consumed that file once the cross-section display landed,
            % and correcting every slide of a 900+ slide stack to sample
            % ~80 of them was the single slowest thing this button did --
            % so only the slides inside the grid planes' own averaging
            % windows are corrected now, and nothing is written to disk.
            if app.grid_SettingStatus ~= 4
                uialert(app.ImageCorrectionDialogUIFigure, ...
                    'Verify Overall Correction needs every plane to be populated first (Populate the Rest must finish).', ...
                    'Not Ready');
                return;
            end

            fig = app.ImageCorrectionDialogUIFigure;
            dlg = uiprogressdlg(fig, 'Title', 'Verifying Overall Correction', 'Cancelable','on');
            cleanupDlg = onCleanup(@() close(dlg)); % closes even if something below errors
            dlg.Message = 'Fitting correction transforms...';
            dlg.Value = 0;

            [afterPlaneImgBuf, completed] = GridBuildCorrectedPlaneImages(app, dlg);
            if ~completed
                GridLog(app, 'Verify Overall Correction: canceled before finishing.');
                return;
            end

            GridShowIntensityCrossSections(app, afterPlaneImgBuf);
            GridLog(app, ['Verify Overall Correction: grid-corrected %d plane windows of "%s" in memory ' ...
                'and plotted the before/after intensity cross-sections.'], app.grid_SizeZ, app.filename_GridRef);
        end

        function [afterPlaneImgBuf, completed] = GridBuildCorrectedPlaneImages(app, dlg)
            % Applies GC to only the raw slides that make up each grid
            % plane's averaging window, summing them exactly the way
            % LoadReferenceImage builds grid_PlaneImgBuf for the
            % uncorrected side -- so the result is directly comparable,
            % plane for plane, without writing a corrected file to disk.
            % completed=false means the user canceled via dlg.
            afterPlaneImgBuf = [];
            completed = false;

            % GridTransformationInitialize needs app.ref_Image's SIZE, and
            % after a Load Settings restore ref_Image/grid_PlaneImgBuf are
            % empty (settings persist grid data, not raw image buffers)
            % until something actually reads the TIFF.
            ChangeRefImagePlane(app);

            file_info = imfinfo(app.filename_GridRef);
            imgSizeZ = numel(file_info);

            Z=zeros(1, app.grid_SizeZ);
            for iGrid=1:app.grid_SizeZ
                Z(iGrid)=app.grid_PlaneStart+(iGrid-1)*app.grid_PlaneInterval;
            end
            Zz=1:1:imgSizeZ;
            grid_Position_Spline=spline(Z, app.grid_Position, Zz);

            [RA, worldPoints, squareSize]=GridTransformationInitialize(app, 1);

            nSlides = app.grid_SizeZ*app.grid_PlaneAveraging;
            slideList = zeros(1, nSlides);
            for z=1:app.grid_SizeZ
                base = GridPlaneSlideNumber(app, z);
                slideList(((z-1)*app.grid_PlaneAveraging+1):(z*app.grid_PlaneAveraging)) = base+(1:app.grid_PlaneAveraging);
            end
            gcTransformSet = GridBuildGCTransforms(app, grid_Position_Spline, worldPoints, squareSize, imgSizeZ, slideList);
            if dlg.CancelRequested
                return;
            end

            tiffReader = Tiff(app.filename_GridRef, 'r');
            cleanupReader = onCleanup(@() close(tiffReader));

            dlg.Message = 'Correcting grid planes...';
            done = 0;
            for z=1:app.grid_SizeZ
                planeSum = [];
                for k=1:app.grid_PlaneAveraging
                    iZ = GridPlaneSlideNumber(app, z)+k;
                    tiffReader.setDirectory(iZ);
                    rawImage = single(tiffReader.read());
                    correctedImage = GridApplyGCTransform(app, gcTransformSet, rawImage, RA, iZ);
                    if isempty(planeSum)
                        planeSum = double(correctedImage);
                    else
                        planeSum = planeSum + double(correctedImage);
                    end

                    done = done+1;
                    dlg.Value = done/nSlides;
                    if dlg.CancelRequested
                        return;
                    end
                end
                if z==1
                    afterPlaneImgBuf = zeros(size(planeSum,1), size(planeSum,2), app.grid_SizeZ);
                end
                afterPlaneImgBuf(:,:,z) = planeSum; %#ok<AGROW> -- preallocated on z==1
            end
            completed = true;
        end

        function GridShowIntensityCrossSections(app, afterPlaneImgBuf)
            % Kymograph-style cross-sections: one ROW per Z-plane, built
            % from the actual pixel-intensity profile along a cut near
            % the grid's center (offset half a cell so it falls BETWEEN
            % two rows/columns of grid points, so every dark grid bar
            % crossing it shows up as a dip). Stacking one profile per
            % plane into a 2D image is the same idea as
            % GridShowCrossSections' point-position-vs-Z plots, but built
            % from real pixel data instead of detected coordinates: an
            % uncorrected stack drifts laterally plane to plane, showing
            % up as SLANTED stripes; a well-corrected stack keeps every
            % plane's dark bars in the same place, showing up as
            % perfectly VERTICAL stripes.
            %
            % afterPlaneImgBuf is the corrected counterpart of
            % grid_PlaneImgBuf (one summed image per grid plane), as
            % GridBuildCorrectedPlaneImages produces it.
            plane = app.grid_PlaneCurrent;
            ChangeRefImagePlane(app); % also guarantees grid_PlaneImgBuf is populated for every z
            [H, W] = size(app.ref_Image);

            nX = app.grid_SizeX; nY = app.grid_SizeY; nZ = app.grid_SizeZ;
            midRow = floor(nY/2); midCol = floor(nX/2); % cut sits between this row/col and the next
            rowAIdx = (midRow-1)*nX + (1:nX);
            rowBIdx = midRow*nX + (1:nX);
            colAIdx = (0:nY-1)*nX + midCol;
            colBIdx = (0:nY-1)*nX + midCol+1;
            band = 4; % average a +/-4px band across the cut to reduce shot noise

            % "Before": cut position is recomputed PER PLANE -- the raw
            % grid drifts/rotates across Z, so a single fixed cut
            % wouldn't stay "between" the same two rows/columns for
            % every plane. grid_PlaneImgBuf already holds every plane's
            % raw summed image (unclamped) from LoadReferenceImage.
            beforeImg = app.grid_PlaneImgBuf(:,:,plane); % for the top-row context image
            beforeCutYCurrent = 0; beforeCutXCurrent = 0;
            beforeXSection = zeros(nZ, W);
            beforeYSection = zeros(nZ, H);
            for z=1:nZ
                gp = app.grid_Position(:,:,z);
                cutY = round(mean([gp(rowAIdx,2); gp(rowBIdx,2)]));
                cutX = round(mean([gp(colAIdx,1); gp(colBIdx,1)]));
                cutY = min(max(cutY, band+1), H-band);
                cutX = min(max(cutX, band+1), W-band);
                planeImg = app.grid_PlaneImgBuf(:,:,z);
                beforeXSection(z,:) = mean(planeImg(cutY-band:cutY+band, :), 1);
                beforeYSection(z,:) = mean(planeImg(:, cutX-band:cutX+band), 2)';
                if z==plane
                    beforeCutYCurrent = cutY;
                    beforeCutXCurrent = cutX;
                end
            end
            beforeImg(beforeImg>3) = 3; % display clamp for the top-row context image only

            % "After": cut position is CONSTANT across Z -- every plane
            % is warped toward the same worldPoints target (always fit
            % against plane 1), so the corrected grid should sit at the
            % same output pixel location regardless of z.
            %
            % Which pixel that is depends on the correction method's
            % output canvas. For the single-transform methods (1-4) the
            % canvas is the raw image's own size viewed through RA, whose
            % world origin sits at plane 1's first raw grid point, so
            % worldPoints values need that leftMargin/topMargin added
            % back. The piecewise methods (5-7) instead assemble their
            % output by indexing worldPoints values directly as pixel
            % positions (see GridApplyGCTransform), so there's no margin
            % to add there.
            [~, worldPoints, ~] = GridTransformationInitialize(app, 1);
            [afterH, afterW, ~] = size(afterPlaneImgBuf);
            if str2double(app.ui_TransformationMethod) < 5
                gp1 = app.grid_Position(:,:,1);
                marginX = gp1(1,1) + app.image_OutputShiftX;
                marginY = gp1(1,2) + app.image_OutputShiftY;
            else
                marginX = 0;
                marginY = 0;
            end
            afterCutY = round(mean([worldPoints(rowAIdx,2); worldPoints(rowBIdx,2)]) + marginY);
            afterCutX = round(mean([worldPoints(colAIdx,1); worldPoints(colBIdx,1)]) + marginX);
            afterCutY = min(max(afterCutY, band+1), afterH-band);
            afterCutX = min(max(afterCutX, band+1), afterW-band);

            afterImg = afterPlaneImgBuf(:,:,plane); % for the top-row context image
            afterXSection = zeros(nZ, afterW);
            afterYSection = zeros(nZ, afterH);
            for z=1:nZ
                sumImg = afterPlaneImgBuf(:,:,z);
                afterXSection(z,:) = mean(sumImg(afterCutY-band:afterCutY+band, :), 1);
                afterYSection(z,:) = mean(sumImg(:, afterCutX-band:afterCutX+band), 2)';
            end
            afterImg(afterImg>3) = 3; % display clamp for the top-row context image only

            % Contrast for the four kymographs: the app-wide [0 3] display
            % clamp (used for beforeImg/afterImg above) is tuned for a
            % SINGLE raw pixel's summed intensity and saturates almost the
            % entire bright-cell interior to pure white once several
            % pixels are averaged together -- pick a data-driven upper
            % limit instead (99th percentile across all four kymographs
            % together, so before/after and X/Y all stay on one shared,
            % comparable scale) to keep some visible gradation there.
            allSectionVals = sort([beforeXSection(:); afterXSection(:); beforeYSection(:); afterYSection(:)]);
            climHi = allSectionVals(max(1, round(0.99*numel(allSectionVals))));
            if climHi <= 0
                climHi = 1;
            end

            figHandle = figure('NumberTitle','off', 'Name', 'Verify Overall Correction -- Intensity Cross-Sections');
            set(figHandle, 'Position', [80 30 1100 980]);

            subplot(3,2,1);
            imshow(beforeImg, [0 3]); hold on;
            yline(beforeCutYCurrent, 'y-', 'LineWidth',1.5);
            xline(beforeCutXCurrent, 'c-', 'LineWidth',1.5);
            hold off;
            title(sprintf('Before Correction (Plane #%d, cut lines shown)', plane));

            subplot(3,2,2);
            imshow(afterImg, [0 3]); hold on;
            yline(afterCutY, 'y-', 'LineWidth',1.5);
            xline(afterCutX, 'c-', 'LineWidth',1.5);
            hold off;
            title(sprintf('After Correction (Plane #%d, cut lines shown)', plane));

            subplot(3,2,3);
            imagesc(1:W, 1:nZ, beforeXSection); colormap(gca,'gray'); clim([0 climHi]);
            xlabel('X position (px)'); ylabel('Plane (Z)');
            title(sprintf('X cross-section, Before (cut between grid rows %d/%d)', midRow, midRow+1));

            subplot(3,2,4);
            imagesc(1:afterW, 1:nZ, afterXSection); colormap(gca,'gray'); clim([0 climHi]);
            xlabel('X position (px)'); ylabel('Plane (Z)');
            title('X cross-section, After');

            subplot(3,2,5);
            imagesc(1:H, 1:nZ, beforeYSection); colormap(gca,'gray'); clim([0 climHi]);
            xlabel('Y position (px)'); ylabel('Plane (Z)');
            title(sprintf('Y cross-section, Before (cut between grid columns %d/%d)', midCol, midCol+1));

            subplot(3,2,6);
            imagesc(1:afterH, 1:nZ, afterYSection); colormap(gca,'gray'); clim([0 climHi]);
            xlabel('Y position (px)'); ylabel('Plane (Z)');
            title('Y cross-section, After');
        end

        function spread = GridCrossSectionSpread(app, gridPositionData)
            % Quantifies how far each grid point's position drifts across
            % Z, for the same middle row/column GridShowCrossSections
            % plots -- a numeric companion to the visual check.
            nX = app.grid_SizeX; nY = app.grid_SizeY;
            midY = ceil(nY/2); midX = ceil(nX/2);
            rowIdx = (midY-1)*nX + (1:nX);   % X cross-section: vary grid_x at fixed grid_y
            colIdx = (0:nY-1)*nX + midX;     % Y cross-section: vary grid_y at fixed grid_x

            xStds = zeros(nX,1);
            for gx=1:nX
                xStds(gx) = std(squeeze(gridPositionData(rowIdx(gx),1,:)));
            end
            yStds = zeros(nY,1);
            for gy=1:nY
                yStds(gy) = std(squeeze(gridPositionData(colIdx(gy),2,:)));
            end
            spread = struct('maxXStd',max(xStds),'meanXStd',mean(xStds), ...
                'maxYStd',max(yStds),'meanYStd',mean(yStds));
        end

        function GridShowCrossSections(app, gridPositionBefore, gridPositionAfter)
            % Displays the X cross-section (a fixed grid row's points,
            % position vs Z) and Y cross-section (a fixed grid column's
            % points, position vs Z), before vs after correction, side by
            % side. Z runs down the vertical axis of each subplot so a
            % well-corrected stack visually shows near-vertical lines --
            % literally the "if we do x and y cross section on the cube,
            % we should see perfectly vertical grid lines" check.
            nX = app.grid_SizeX; nY = app.grid_SizeY; nZ = app.grid_SizeZ;
            midY = ceil(nY/2); midX = ceil(nX/2);
            rowIdx = (midY-1)*nX + (1:nX);
            colIdx = (0:nY-1)*nX + midX;
            zAxis = 1:nZ;

            figHandle = figure('NumberTitle','off','Name','Verify Overall Correction -- X/Y Cross-Sections');
            set(figHandle, 'Position', [100 100 900 700]);

            datasets = {gridPositionBefore, 'Before Correction'; gridPositionAfter, 'After Correction'};
            cmapX = lines(nX);
            cmapY = lines(nY);

            for col = 1:2
                gp = datasets{col,1};
                titleSuffix = datasets{col,2};

                subplot(2,2,col);
                hold on;
                for gx=1:nX
                    xvals = squeeze(gp(rowIdx(gx),1,:));
                    plot(xvals, zAxis, '-o', 'Color', cmapX(gx,:), 'MarkerSize',3, 'LineWidth',1);
                end
                set(gca,'YDir','reverse');
                xlabel('X position (px)'); ylabel('Plane (Z)');
                title(sprintf('X cross-section (row Y=%d): %s', midY, titleSuffix));
                grid on;
                hold off;

                subplot(2,2,2+col);
                hold on;
                for gy=1:nY
                    yvals = squeeze(gp(colIdx(gy),2,:));
                    plot(yvals, zAxis, '-o', 'Color', cmapY(gy,:), 'MarkerSize',3, 'LineWidth',1);
                end
                set(gca,'YDir','reverse');
                xlabel('Y position (px)'); ylabel('Plane (Z)');
                title(sprintf('Y cross-section (col X=%d): %s', midX, titleSuffix));
                grid on;
                hold off;
            end
        end


        function latticeModel = GridAlignPlanePhase(app, plane, latticeModel)
            % Correct a systematic "off by N grid periods" phase error.
            % FFT-based spacing/orientation detection is essentially
            % unaffected by blur or low contrast (it depends on
            % periodicity, not phase), but the phase/origin step
            % (GridProjectedPhase) can occasionally lock onto the wrong
            % grid line under those conditions -- shifting EVERY
            % predicted crossing in the plane by the same integer number
            % of periods (e.g. "the whole grid offset by a row"). This
            % looks perfectly self-consistent within the plane -- nothing
            % looks like an outlier -- so it can only be caught by
            % comparing against a trusted reference plane.
            %
            % Always use plane 1 as that reference (not the immediately
            % preceding plane): plane 1 is the one the user can directly
            % verify/correct via "Adjust Grid Origin" before "Populate the
            % rest" ever runs, so it's the most trustworthy fixed point to
            % anchor every other plane to -- comparing to a chain of
            % previous planes instead would let a single bad plane's error
            % propagate into being the (wrong) reference for the next one.
            if plane < 2 || numel(app.grid_LatticeModel) < 1 || isempty(app.grid_LatticeModel{1})
                return;
            end
            refModel = app.grid_LatticeModel{1};

            % Each plane's (d1,u1)/(d2,u2) axis labels are assigned
            % independently ("more horizontal = axis 1"), so a plane
            % whose average rotation sits near that labeling boundary can
            % get its two axes swapped relative to the reference plane.
            % Left uncorrected, that swap looks exactly like a spurious
            % whole-period offset on the mismatched axis -- realign the
            % labels to the reference before decomposing the offset.
            if dot(latticeModel.u1, refModel.u2) > dot(latticeModel.u1, refModel.u1)
                [latticeModel.d1, latticeModel.d2] = deal(latticeModel.d2, latticeModel.d1);
                [latticeModel.u1, latticeModel.u2] = deal(latticeModel.u2, latticeModel.u1);
                [latticeModel.theta1, latticeModel.theta2] = deal(latticeModel.theta2, latticeModel.theta1);
                GridLog(app, 'Plane %d: axis labels swapped to match plane 1 before phase check.', plane);
            end

            % Express the origin discrepancy in lattice-basis (period)
            % coordinates: an integer result means the phase locked onto
            % the wrong grid line by that many periods.
            A = [latticeModel.d1*latticeModel.u1(:), latticeModel.d2*latticeModel.u2(:)];
            offset = (latticeModel.origin_xy - refModel.origin_xy)';
            periodCoords = A \ offset;
            nearestInt = round(periodCoords);
            residual = periodCoords - nearestInt;

            GridLog(app, 'Plane %d: phase check vs plane 1 -> period offset=[%.3f, %.3f], residual norm=%.3f', ...
                plane, periodCoords(1), periodCoords(2), norm(residual));

            if any(nearestInt ~= 0) && norm(residual) < 0.3
                correction = (A * nearestInt)';
                latticeModel.origin_xy = latticeModel.origin_xy - correction;
                GridLog(app, ['Plane %d: detected grid phase was off by [%d, %d] whole periods ' ...
                     'from plane 1 -- corrected automatically.'], ...
                    plane, nearestInt(1), nearestInt(2));
            end
        end

        function GridOptimizePlaneUntilConverged(app, plane, latticeModel, maxPasses)
            % Repeatedly predict->refine->smooth this plane, re-seeding
            % each pass from the previous pass's smooth-surface
            % prediction, until the number of genuinely well-fit
            % crossings stops improving (or nearly every point has
            % converged) -- rather than a fixed pass count. This is
            % exactly what manually clicking "Optimize This Plane" a
            % couple more times used to be needed for (a few scattered
            % points converge only on a later pass, once their search
            % window is centered from an already-improved surface
            % rather than the raw/first-pass estimate); now it happens
            % automatically, bounded by maxPasses so it can't loop
            % forever on a plane that will never fully converge.
            nTotal = app.grid_SizeX*app.grid_SizeY;
            prevGoodCount = -1;
            for pass = 1:maxPasses
                if pass == 1
                    GridPopulatePlaneAuto(app, plane, latticeModel);
                else
                    refinedModel = GridLatticeFromSurface(app, plane);
                    GridPopulatePlaneAuto(app, plane, refinedModel);
                end
                GridFitSmoothSurface(app, plane);

                nGoodNow = 0;
                for index = 1:nTotal
                    infoIdx = app.grid_Info{index, plane};
                    if isstruct(infoIdx) && isfield(infoIdx,'status') && infoIdx.status==1 ...
                            && isfield(infoIdx,'fitOK') && infoIdx.fitOK
                        nGoodNow = nGoodNow + 1;
                    end
                end
                GridLog(app, 'Plane %d: pass %d/%d -> %d/%d converged', plane, pass, maxPasses, nGoodNow, nTotal);
                if nGoodNow <= prevGoodCount || nGoodNow >= nTotal*0.98
                    break; % no more improvement, or effectively fully converged
                end
                prevGoodCount = nGoodNow;
            end
        end

        function GridPlaceRawLatticePositions(app, plane, latticeModel)
            % Skip local refinement/smoothing entirely -- just place each
            % crossing at its raw predicted lattice position. Used when
            % the user has unchecked "Optimize Grid Crossings" for a fast,
            % un-refined preview.
            for grid_y=1:app.grid_SizeY
                for grid_x=1:app.grid_SizeX
                    index=(grid_y-1)*app.grid_SizeX+grid_x;
                    pos = GridPredictPosition(app, latticeModel, grid_x, grid_y);
                    app.grid_Position(index,:,plane) = pos;
                    app.grid_Info{index,plane}.rawPos = pos;
                    app.grid_Info{index,plane}.fitOK = false;
                    app.grid_Info{index,plane}.status = 0;
                    app.grid_Info{index,plane}.source = 'lattice-raw';
                end
            end
        end

        function latticeModel = GridLatticeFromCurrentPositions(app, plane)
            % Build a lattice-model-shaped seed from whatever is CURRENTLY
            % in grid_Position for this plane -- the raw lattice guess, a
            % prior optimization pass, or manually-nudged points (dragged
            % via the interactive display) -- so "Optimize This Plane" can
            % be run on demand, any time, regardless of how the plane got
            % its current positions.
            nTotal = app.grid_SizeX*app.grid_SizeY;
            predictedPos = zeros(nTotal,2);
            for grid_y=1:app.grid_SizeY
                for grid_x=1:app.grid_SizeX
                    index=(grid_y-1)*app.grid_SizeX+grid_x;
                    predictedPos(index,:) = app.grid_Position(index,:,plane);
                end
            end

            if numel(app.grid_SurfaceModel) >= plane && ~isempty(app.grid_SurfaceModel{plane})
                % Prefer the locally-accurate, surface-gradient-based
                % spacing/direction for orienting each point's search
                % patch; only its localSpacing is used here, not its
                % (possibly stale) predictedPos, so manual nudges are
                % respected.
                surfaceLattice = GridLatticeFromSurface(app, plane);
                localSpacing = surfaceLattice.localSpacing;
            elseif numel(app.grid_LatticeModel) >= plane && ~isempty(app.grid_LatticeModel{plane})
                base = app.grid_LatticeModel{plane};
                localSpacing = { ...
                    repmat(base.d1*base.u1, nTotal, 1), ...
                    repmat(base.d2*base.u2, nTotal, 1)};
            else
                % Neither model is available. This is the normal state for
                % a settings file saved before grid_LatticeModel existed
                % (pre-V7) -- such a file restores grid_Position fine, so
                % every point draws correctly, and only optimizing failed.
                % grid_SurfaceModel is never written to a settings file by
                % ANY version, so it is always missing after a load too.
                %
                % The populated positions themselves still carry the local
                % spacing and orientation, so measure it from them rather
                % than refusing to run: exactly what GridLatticeFromSurface
                % does, just differencing the real points instead of the
                % fitted surface.
                localSpacing = GridLocalSpacingFromPositions(app, predictedPos);
            end

            latticeModel.predictedPos = predictedPos;
            latticeModel.localSpacing = localSpacing;
        end

        function localSpacing = GridLocalSpacingFromPositions(app, positions)
            % Per-point grid step vectors measured straight off the given
            % positions: localSpacing{1} is the image-space step for +1 in
            % grid_x, localSpacing{2} for +1 in grid_y -- the same meaning
            % and ordering GridLatticeFromSurface produces.
            %
            % gradient() gives central differences in the interior and
            % one-sided ones at the edges, over unit steps in grid-index
            % space, which is precisely the finite difference wanted here.
            % Its FIRST output differences along COLUMNS and its second
            % along ROWS; positions are reshaped so rows are grid_x and
            % columns grid_y (index = (grid_y-1)*grid_SizeX + grid_x), so
            % the outputs come back swapped relative to the naming.
            nX = app.grid_SizeX; nY = app.grid_SizeY;
            if nX < 2 || nY < 2
                error('GridCorrection:GridTooSmall', ...
                    ['Cannot measure grid spacing from a %dx%d grid -- at least 2 points ' ...
                     'are needed along each axis.'], nX, nY);
            end
            posX = reshape(positions(:,1), nX, nY);
            posY = reshape(positions(:,2), nX, nY);

            [posX_dgy, posX_dgx] = gradient(posX);
            [posY_dgy, posY_dgx] = gradient(posY);

            localSpacing = { ...
                [posX_dgx(:) posY_dgx(:)], ...
                [posX_dgy(:) posY_dgy(:)]};
        end

        function latticeModel = GridLatticeModelFromPositions(app, plane)
            % Reconstruct a plane's global lattice model (spacing,
            % orientation, origin) by measuring it from that plane's
            % already-populated grid_Position, for settings files that
            % predate grid_LatticeModel being saved at all.
            %
            % Same fields and conventions as GridAutoDetectLattice /
            % GridLatticeFromConvergedPoints produce, so every consumer
            % downstream sees a normal model. Marked trusted/confident
            % because these points come from a grid the user already set
            % up and saved, not from a fresh automatic detection.
            positions = app.grid_Position(:,:,plane);
            localSpacing = GridLocalSpacingFromPositions(app, positions);
            v1 = mean(localSpacing{1}, 1);
            v2 = mean(localSpacing{2}, 1);
            d1 = norm(v1);
            d2 = norm(v2);
            u1 = v1/d1;
            u2 = v2/d2;

            originIndex = [ceil(app.grid_SizeX/2) ceil(app.grid_SizeY/2)];
            origin_xy = positions((originIndex(2)-1)*app.grid_SizeX + originIndex(1), :);

            latticeModel = struct('d1',d1, 'd2',d2, ...
                'theta1',atan2d(u1(2),u1(1)), 'theta2',atan2d(u2(2),u2(1)), ...
                'u1',u1, 'u2',u2, 'origin_xy',origin_xy, 'originIndex',originIndex, ...
                'detectStatus',1, 'confidence',1, 'trusted',true);
        end

        function GridEnsureLatticeModels(app)
            % Rebuild any missing per-plane lattice model from the loaded
            % positions. Settings files written before grid_LatticeModel
            % was added restore grid_Position perfectly -- every point
            % draws in the right place -- but leave grid_LatticeModel
            % empty, and the refinement path assumes a populated plane
            % always has one: "Optimize This Plane" failed with "No
            % lattice model available", and GridLatticeFromSurface
            % indexed straight into the empty cell array. Restoring the
            % invariant here fixes every consumer at once instead of
            % teaching each one to cope with a missing model.
            if isempty(app.grid_Position) || app.grid_SizeX < 2 || app.grid_SizeY < 2
                return;
            end
            nPlanes = min(app.grid_SizeZ, size(app.grid_Position,3));
            for plane = 1:nPlanes
                if numel(app.grid_LatticeModel) >= plane && ~isempty(app.grid_LatticeModel{plane})
                    continue;
                end
                if ~any(app.grid_Position(:,:,plane), 'all')
                    continue; % plane was never populated -- nothing to measure
                end
                app.grid_LatticeModel{plane} = GridLatticeModelFromPositions(app, plane);
                GridLog(app, ['Plane %d: lattice model rebuilt from the saved grid points ' ...
                    '(d1=%.2f d2=%.2f, rotation %.1f/%.1fdeg) -- settings file predates it being saved.'], ...
                    plane, app.grid_LatticeModel{plane}.d1, app.grid_LatticeModel{plane}.d2, ...
                    app.grid_LatticeModel{plane}.theta1, app.grid_LatticeModel{plane}.theta2);
            end
        end

        function GridCloseFigures(~)
            % Close every plain (non-uifigure) figure window this app may
            % have created -- fitting-debug plots (2), correction-test
            % before/after views (2/3) -- so none are left orphaned
            % however the app gets closed. (The grid-point editor no
            % longer opens a separate figure(1) -- it's GridAxes/
            % GridSidebarUI inside the main uifigure now, closed along
            % with it.) Uses findall (never creates a figure, unlike
            % calling figure(N) directly) and tolerates figures that no
            % longer exist.
            for figNum = 2:3
                figHandles = findall(groot, 'Type', 'figure', 'Number', figNum);
                for k = 1:numel(figHandles)
                    try
                        delete(figHandles(k));
                    catch
                        % already gone -- nothing to do
                    end
                end
            end
        end

        function GridLog(app, fmt, varargin)
            % Print a step-by-step progress line, only when "Verbose
            % Output" is checked. Plain fprintf (not warning()), so it
            % never carries a call-stack, and is silent by default.
            if app.ui_VerboseOutput
                fprintf(['[GridCorrection] ' fmt '\n'], varargin{:});
            end
        end

        function GridFitZSmoothing(app)
            % Correlate grid-crossing positions ACROSS Z planes: the
            % physical grid doesn't change shape between planes -- only
            % the sample stage/optics drift slowly across the eV/focus
            % series -- so a plane whose own measurement was poor (e.g.
            % blurry) can be corrected using the trend from planes that
            % measured well.
            %
            % Two failure modes this guards against (both seen in
            % practice): (1) an unweighted fit across all planes lets
            % noisy/bad planes pull an already well-determined plane's
            % position away from its own good measurement; (2) a
            % systematically bad plane (e.g. every point in a blurry
            % plane is off in a similar way) doesn't look like a
            % point-level outlier WITHIN that plane, so within-plane
            % checks alone don't catch it.
            %
            % Fix: only TRUSTED planes -- ones with a genuine converged
            % local measurement (source=='lattice', fitOK), not flagged
            % an outlier by the within-plane surface fit (status~=2), AND
            % from a plane whose own auto-detected lattice was confident
            % -- are used to fit the cross-plane trend. Only NON-trusted
            % planes are then replaced by that trend; a trusted plane's
            % own directly-measured position is never touched.
            nX = app.grid_SizeX;
            nY = app.grid_SizeY;
            nZ = app.grid_SizeZ;
            nTotal = nX*nY;

            if nZ < 3 || numel(app.grid_Info) < nTotal*nZ
                return; % not enough planes to fit any meaningful Z trend
            end

            planeTrustedFlag = false(nZ,1);
            planeQuality = ones(nZ,1);
            for z = 1:nZ
                if numel(app.grid_LatticeModel) >= z && ~isempty(app.grid_LatticeModel{z})
                    % Prefer the real trust flag (GridUpdatePlaneTrust --
                    % point-level quality AND consistency with the Z-trend
                    % at the time this plane was seeded); fall back to the
                    % raw FFT confidence flag only for settings saved
                    % before this field existed. The raw flag alone isn't
                    % enough on its own -- it only sanity-checks internal
                    % consistency and can still be confidently wrong (see
                    % GridSeedPlaneLattice's header comment).
                    if isfield(app.grid_LatticeModel{z},'trusted')
                        planeTrustedFlag(z) = app.grid_LatticeModel{z}.trusted;
                    elseif isfield(app.grid_LatticeModel{z},'confidence')
                        planeTrustedFlag(z) = app.grid_LatticeModel{z}.confidence >= 1;
                    end
                end
                if numel(app.grid_SurfaceModel) >= z && ~isempty(app.grid_SurfaceModel{z}) ...
                        && isfield(app.grid_SurfaceModel{z},'qualityFraction')
                    % Fraction of this plane's crossings that had a
                    % genuine converged local fit -- a low fraction
                    % (e.g. a blurry/low-contrast plane where most points
                    % failed and had to be filled in from its own
                    % within-plane surface fit) means this plane shouldn't
                    % be trusted as a reference for correcting others,
                    % even if no single point looks like an outlier.
                    planeQuality(z) = app.grid_SurfaceModel{z}.qualityFraction;
                end
            end

            zIndex = (1:nZ)';
            minTrusted = 3;
            nCorrected = 0;

            for index = 1:nTotal
                xVals = zeros(nZ,1);
                yVals = zeros(nZ,1);
                populated = false(nZ,1);
                trusted = false(nZ,1);
                for z = 1:nZ
                    info = app.grid_Info{index, z};
                    if ~isstruct(info) || ~isfield(info,'source')
                        continue;
                    end
                    populated(z) = true;
                    xVals(z) = app.grid_Position(index,1,z);
                    yVals(z) = app.grid_Position(index,2,z);

                    isGenuineMeasurement = strcmp(info.source,'lattice') && ...
                        isfield(info,'fitOK') && info.fitOK;
                    isNotOutlier = ~isfield(info,'status') || info.status ~= 2;
                    trusted(z) = isGenuineMeasurement && isNotOutlier && ...
                        planeTrustedFlag(z) && planeQuality(z) >= 0.5;
                end

                nTrusted = nnz(trusted);
                if nTrusted < minTrusted
                    continue; % not enough trustworthy planes to establish a
                              % trend for this point -- leave every plane's
                              % own value exactly as it was
                end

                zOrder = 'poly1';
                if nTrusted >= 6
                    zOrder = 'poly2';
                end

                warnState = warning('off','curvefit:fit:iterationLimitReached'); % benign on very clean data
                sfXz = fit(zIndex(trusted), xVals(trusted), zOrder, 'Robust','Bisquare');
                sfYz = fit(zIndex(trusted), yVals(trusted), zOrder, 'Robust','Bisquare');
                warning(warnState);

                for z = 1:nZ
                    % Only replace planes that were populated but NOT
                    % trusted -- a trusted plane's own measurement is left
                    % untouched, and an unpopulated plane is left as-is.
                    if trusted(z) || ~populated(z)
                        continue;
                    end
                    app.grid_Position(index,:,z) = [sfXz(z) sfYz(z)];
                    app.grid_Info{index,z}.zSmoothed = true;
                    app.grid_Info{index,z}.source = 'z-trend';
                    app.grid_Info{index,z}.status = 1;
                    nCorrected = nCorrected + 1;
                end
            end
            GridLog(app, 'Z-correlation: %d crossing(s) across all planes replaced using trusted-plane trends.', nCorrected);
        end

        function latticeModel = GridLatticeFromZHistory(app, plane, fallbackModel)
            % Build a per-point seed for `plane`'s FIRST optimization pass
            % by extrapolating each crossing's own TRUSTED history across
            % previously-processed planes (1..plane-1), rather than
            % starting fresh from a uniform lattice every time. Real
            % per-point distortion and slow drift are already reflected
            % in that history, so this seed typically lands much closer
            % to the truth than a from-scratch guess -- converging faster
            % and more robustly under weak signal.
            %
            % This does NOT reintroduce the old plane-to-plane propagation
            % bug: every point is still independently re-verified by the
            % same bounded local Gaussian-dip search regardless of where
            % its seed came from (a bad seed just fails to converge --
            % GridPositionOptimize doesn't blindly trust it), and only
            % TRUSTED planes (same criteria as GridFitZSmoothing: genuine
            % converged fit, not flagged an outlier, confident/good-
            % quality plane) ever feed this history. A bad plane still
            % cannot poison later planes.
            %
            % Extrapolation order per point matches the plane-level
            % GridLatticeTrendPredict convention: linear with only 3-5
            % trusted planes behind it, quadratic once 6+ exist. A
            % quadratic fit is cross-checked against a LOCAL linear fit
            % over just its most recent few trusted planes, since
            % polynomial extrapolation can swing sharply once queried
            % past the range it was fitted on -- a large disagreement
            % there falls back to the safer local-linear estimate rather
            % than trusting the riskier extrapolation blindly.
            %
            % Falls back to fallbackModel (this plane's own fresh,
            % independent FFT-based auto-detected lattice) for any point
            % without enough trusted history yet -- e.g. very early
            % planes, or a point that never converged on any prior plane.
            nX = app.grid_SizeX;
            nY = app.grid_SizeY;
            nTotal = nX*nY;

            if plane < 2
                latticeModel = fallbackModel;
                return;
            end

            planeTrustedFlag = false(plane-1,1);
            planeQuality = ones(plane-1,1);
            for z = 1:plane-1
                if numel(app.grid_LatticeModel) >= z && ~isempty(app.grid_LatticeModel{z})
                    if isfield(app.grid_LatticeModel{z},'trusted')
                        planeTrustedFlag(z) = app.grid_LatticeModel{z}.trusted;
                    elseif isfield(app.grid_LatticeModel{z},'confidence')
                        planeTrustedFlag(z) = app.grid_LatticeModel{z}.confidence >= 1;
                    end
                end
                if numel(app.grid_SurfaceModel) >= z && ~isempty(app.grid_SurfaceModel{z}) ...
                        && isfield(app.grid_SurfaceModel{z},'qualityFraction')
                    planeQuality(z) = app.grid_SurfaceModel{z}.qualityFraction;
                end
            end

            predictedPos = zeros(nTotal,2);
            haveHistory = false(nTotal,1);
            % A large disagreement between a higher-order fit (using ALL
            % trusted history) and a LOCAL linear fit (just the most
            % recent few trusted planes) at the query z is a red flag --
            % polynomial extrapolation can swing sharply once queried
            % outside the range it was fitted on, and when the two
            % disagree by more than this, the higher-order answer is the
            % one more likely to be wrong (it's the one doing the riskier
            % extrapolation), so fall back to the safer local-linear
            % value. Matches the ~3px floor GridFitSmoothSurface already
            % uses for its own outlier threshold.
            maxPlausibleDisagreementPx = 3;
            nDowngraded = 0;
            nLinear = 0;
            nQuadratic = 0;
            nCarryForward = 0;

            for grid_y = 1:nY
                for grid_x = 1:nX
                    index = (grid_y-1)*nX+grid_x;
                    zHist = [];
                    xHist = [];
                    yHist = [];
                    for z = 1:plane-1
                        info = app.grid_Info{index, z};
                        if ~isstruct(info) || ~isfield(info,'source')
                            continue;
                        end
                        isGenuineMeasurement = strcmp(info.source,'lattice') && ...
                            isfield(info,'fitOK') && info.fitOK;
                        isNotOutlier = ~isfield(info,'status') || info.status ~= 2;
                        if isGenuineMeasurement && isNotOutlier && ...
                                planeTrustedFlag(z) && planeQuality(z) >= 0.5
                            zHist(end+1) = z; %#ok<AGROW>
                            xHist(end+1) = app.grid_Position(index,1,z); %#ok<AGROW>
                            yHist(end+1) = app.grid_Position(index,2,z); %#ok<AGROW>
                        end
                    end

                    nHist = numel(zHist);
                    if nHist >= 3
                        % Same order convention as the plane-level
                        % GridLatticeTrendPredict: quadratic once there's
                        % enough history to support it, linear with only a
                        % handful of trusted planes (3-5) -- a poly2 fit
                        % on that few points would just interpolate
                        % perfectly with no robustness, not capture a real
                        % curved trend.
                        zOrder = 'poly1';
                        if nHist >= 6
                            zOrder = 'poly2';
                            nQuadratic = nQuadratic + 1;
                        else
                            nLinear = nLinear + 1;
                        end
                        warnState = warning('off','curvefit:fit:iterationLimitReached');
                        sfXz = fit(zHist(:), xHist(:), zOrder, 'Robust','Bisquare');
                        sfYz = fit(zHist(:), yHist(:), zOrder, 'Robust','Bisquare');
                        warning(warnState);
                        predVal = [sfXz(plane) sfYz(plane)];

                        if strcmp(zOrder,'poly2')
                            nLocal = min(4, nHist);
                            zLocal = zHist(end-nLocal+1:end);
                            xLocal = xHist(end-nLocal+1:end);
                            yLocal = yHist(end-nLocal+1:end);
                            warnState = warning('off','curvefit:fit:iterationLimitReached');
                            sfXzLocal = fit(zLocal(:), xLocal(:), 'poly1', 'Robust','Bisquare');
                            sfYzLocal = fit(zLocal(:), yLocal(:), 'poly1', 'Robust','Bisquare');
                            warning(warnState);
                            localVal = [sfXzLocal(plane) sfYzLocal(plane)];

                            if hypot(predVal(1)-localVal(1), predVal(2)-localVal(2)) > maxPlausibleDisagreementPx
                                predVal = localVal;
                                nDowngraded = nDowngraded + 1;
                            end
                        end

                        predictedPos(index,:) = predVal;
                        haveHistory(index) = true;
                    elseif nHist >= 1
                        % Not enough points for a trend yet -- carry the
                        % last trusted value forward as the best available
                        % guess (still better than a from-scratch lattice
                        % guess for a point with known real distortion).
                        predictedPos(index,:) = [xHist(end) yHist(end)];
                        haveHistory(index) = true;
                        nCarryForward = nCarryForward + 1;
                    end
                end
            end
            GridLog(app, ['Plane %d: per-point Z-history seeding -- %d point(s) quadratic, %d linear, ' ...
                '%d carried forward (insufficient history), %d quadratic downgraded to local-linear ' ...
                '(disagreed by >%.0fpx).'], plane, nQuadratic, nLinear, nCarryForward, nDowngraded, ...
                maxPlausibleDisagreementPx);

            if ~any(haveHistory)
                latticeModel = fallbackModel;
                return;
            end

            for grid_y = 1:nY
                for grid_x = 1:nX
                    index = (grid_y-1)*nX+grid_x;
                    if ~haveHistory(index)
                        predictedPos(index,:) = GridPredictPosition(app, fallbackModel, grid_x, grid_y);
                    end
                end
            end

            % Local spacing/direction for orienting each point's search
            % patch: reuse this plane's own independently-measured (and
            % phase-aligned) spacing/orientation -- that's already a
            % fresh, direct FFT measurement for this exact plane and
            % doesn't need any history.
            localSpacing1 = repmat(fallbackModel.d1*fallbackModel.u1, nTotal, 1);
            localSpacing2 = repmat(fallbackModel.d2*fallbackModel.u2, nTotal, 1);

            latticeModel.predictedPos = predictedPos;
            latticeModel.localSpacing = {localSpacing1, localSpacing2};
        end
    end


    % Callbacks that handle component events
    methods (Access = private)

        % Code that executes after component creation
        function startupFcn(app, varargin)
            if(nargin>1)
                app.parentApp=varargin{1};
            end
            app.workingDirectory=pwd;

            % Establishes the initial Grid-page enable/disable state (grid
            % size fields editable, Quick Setup disabled until a
            % reference image is chosen) and pushes the first view model
            % so the HTML page reflects real app state as soon as it loads.
            GridSettingStatusChange(app, 0);
            GridMarkStateSaved(app); % a blank app has nothing unsaved yet
        end

        % Button pushed function: SaveSettingsButton
        function SaveSettingsButtonPushed(app, event)
            % Propose a default filename derived from the grid reference
            % image, e.g. "GC 20260212_1_30kcps_settings.mat" -- much
            % easier to tell settings files apart later than a generic
            % blank/default name, especially once several exist.
            defaultName = 'settings.mat';
            if ~strcmp(app.filename_GridRef, 'none')
                [~, baseName] = fileparts(app.filename_GridRef);
                defaultName = [baseName '_settings.mat'];
            end
            [filename,filepath]=uiputfile('*.mat','Save Current settings', defaultName);
            if filename == 0
                return;
            end

            filename=[filepath filename];
            app.filename_CurrentSettings=filename;
            
            Parameters.fig_Grid_InitHandleReady=app.fig_Grid_InitHandleReady;
            Parameters.grid_Init_Position=app.grid_Init_Position;

            Parameters.grid_SizeX=app.grid_SizeX;
            Parameters.grid_SizeY=app.grid_SizeY;
            Parameters.grid_SizeZ=app.grid_SizeZ;
            Parameters.grid_PlaneStart=app.grid_PlaneStart;
            Parameters.grid_PlaneAveraging=app.grid_PlaneAveraging;
            Parameters.grid_PlaneInterval=app.grid_PlaneInterval;
            Parameters.grid_Position=app.grid_Position;
            Parameters.grid_Info=app.grid_Info;
            Parameters.grid_SettingStatus=app.grid_SettingStatus;
            Parameters.grid_TransformationMethod=app.ui_TransformationMethod;
            Parameters.filename_GridRef=app.filename_GridRef;
            Parameters.filename_Flatfield=app.filename_Flatfield;
            Parameters.filename_CurrentSettings=app.filename_CurrentSettings;
            Parameters.filename_GeometricDistortion=app.filename_GeometricDistortion;
            Parameters.applyFF=app.ui_ApplyFF;
            Parameters.applyGridDistortionCorrection=app.ui_ApplyGC;
            Parameters.applyObjectiveDistortionCorrection=app.ui_ApplyDC;

            Parameters.image_OutputShiftX=app.image_OutputShiftX;
            Parameters.image_OutputShiftY=app.image_OutputShiftY;

            Parameters.grid_LatticeModel=app.grid_LatticeModel;
            Parameters.grid_AutoDetectEnabled=app.grid_AutoDetectEnabled;
            Parameters.optimizeGridCrossings=app.ui_OptimizeGrid;
            Parameters.grid_RefinementPasses=app.grid_RefinementPasses;

            save(filename, 'Parameters');
            GridMarkStateSaved(app);

        end

        % Button pushed function: LoadSettingsButton
        function LoadSettingsButtonPushed(app, event)
            % Always show the real file picker -- same reasoning as
            % ChangeRefImageButtonPushed. This used to be gated on
            % app.debug==0, but app.debug defaults to 1, so this always
            % silently fell through to a hardcoded relative path
            % ('Distortion Grid\GC_20221219v2.mat') that doesn't exist on
            % a real system, failed inside the try/catch below, and gave
            % no visible error -- which is why "Load Settings" looked
            % like it simply didn't work.
            [filename,filepath]=uigetfile('*.mat','Load old settings');
            if filename == 0
                return;
            end

            filename=[filepath filename];
            app.filename_CurrentSettings=filename;
            
          try
            load(filename, 'Parameters');
            
            app.fig_Grid_InitHandleReady=Parameters.fig_Grid_InitHandleReady;
            app.grid_Init_Position=Parameters.grid_Init_Position;
            app.grid_SizeX=Parameters.grid_SizeX;
            app.grid_SizeY=Parameters.grid_SizeY;
            app.grid_SizeZ=Parameters.grid_SizeZ;
            app.grid_PlaneStart=Parameters.grid_PlaneStart;
            app.grid_PlaneAveraging=Parameters.grid_PlaneAveraging;
            app.grid_PlaneInterval=Parameters.grid_PlaneInterval;
            app.grid_Position=Parameters.grid_Position;
            app.grid_Info=Parameters.grid_Info;
            app.grid_SettingStatus=Parameters.grid_SettingStatus;
            app.ui_TransformationMethod=Parameters.grid_TransformationMethod;
            app.filename_GridRef=Parameters.filename_GridRef;
            app.filename_Flatfield=Parameters.filename_Flatfield;
            app.filename_CurrentSettings=Parameters.filename_CurrentSettings;
            app.filename_GeometricDistortion=Parameters.filename_GeometricDistortion;
            app.ui_ApplyFF=Parameters.applyFF;
            app.ui_ApplyGC=Parameters.applyGridDistortionCorrection;
            app.ui_ApplyDC=Parameters.applyObjectiveDistortionCorrection;
            app.image_OutputShiftX=Parameters.image_OutputShiftX;
            app.image_OutputShiftY=Parameters.image_OutputShiftY;

            if isfield(Parameters,'grid_LatticeModel')
                app.grid_LatticeModel=Parameters.grid_LatticeModel;
            else
                app.grid_LatticeModel={};
            end
            if isfield(Parameters,'grid_AutoDetectEnabled')
                app.grid_AutoDetectEnabled=Parameters.grid_AutoDetectEnabled;
            else
                app.grid_AutoDetectEnabled=true;
            end
            if isfield(Parameters,'optimizeGridCrossings')
                app.ui_OptimizeGrid=Parameters.optimizeGridCrossings;
            else
                app.ui_OptimizeGrid=true;
            end
            if isfield(Parameters,'grid_RefinementPasses')
                app.grid_RefinementPasses=Parameters.grid_RefinementPasses;
            else
                app.grid_RefinementPasses=2;
            end
          catch ME
                 app.filename_CurrentSettings='Invalid file!';
                 uialert(app.ImageCorrectionDialogUIFigure, ...
                     sprintf('Could not load settings from this file: %s', ME.message), ...
                     'Load Settings Failed');
          end
            % Older files carry grid_Position but no lattice models -- see
            % GridEnsureLatticeModels. Also drop any surface models left
            % from a previously-loaded grid: they are never saved, so
            % whatever is in memory belongs to the PREVIOUS settings and
            % would be silently reused against these new positions.
            app.grid_SurfaceModel = {};
            GridEnsureLatticeModels(app);

            SetGridPlaneParameter(app);

            GridSettingStatusChange(app, app.grid_SettingStatus);
            app.grid_PlaneCurrent=1;
            GridUpdatePlaneLabel(app);
            GridMarkStateSaved(app); % freshly loaded state matches the file on disk


        end

        % Close request function: ImageCorrectionDialogUIFigure
        function ImageCorrectionDialogUIFigureCloseRequest(app, event)
            
            if GridHasUnsavedChanges(app) && ~app.debug
                % Only worth asking when something would actually be lost:
                % nothing changed since the last save/load means there is
                % nothing to save (see GridSettingsFingerprint).
                %
                % (Skipped entirely in debug mode -- a scripted/headless
                % close can't click this modal, and auto-selecting "Yes"
                % would trigger SaveSettingsButtonPushed's own uiputfile,
                % which would just hang the same way. "No" is the safe
                % default: it never overwrites a real settings file.)
                fig=app.ImageCorrectionDialogUIFigure;
                msg='Save settings before closing?';
                title='Closing application';
                selection=uiconfirm(fig, msg, title, 'Options', {'Yes', 'No', 'Cancel'}, 'DefaultOption', 1);

                switch(selection)
                    case 'Yes'
                        SaveSettingsButtonPushed(app);
                    case 'No'
                        %no nothing
                    case 'Cancel'
                        return;
                end
            end
            
            if isobject(app.parentApp)
                app.parentApp.ImagePostProcessing.Enable = 'on';
            end

            GridCloseFigures(app);
            delete(app);
        end

        % Button pushed function: ChangeFlatfieldImageButton
        function ChangeFlatfieldImageButtonPushed(app, event)
            if app.debug
                % No known real flatfield sample to point at for scripted
                % testing -- behave as if the picker was cancelled (same
                % as leaving filename_Flatfield at its 'none' default)
                % rather than blocking on a picker nothing can click.
                return;
            end
            [ff_filename,ff_filepath]=uigetfile('*.tiff;*.tif','Choose a flatfield image');
            if ff_filename == 0
                return;
            end

            app.filename_Flatfield=[ff_filepath ff_filename];

        end

        % Button pushed function: ChangeRefImageButton
        function ChangeRefImageButtonPushed(app, event)
            % Always show the real file picker here -- this button is how
            % the user chooses which actual reference image to work with,
            % so it should never silently fall back to a hardcoded
            % developer test file regardless of app.debug (that flag still
            % gates other developer/testing conveniences elsewhere, e.g.
            % ConfirmGridReinit's dialog bypass -- just not this one).
            [filename,filepath]=uigetfile('*.tiff;*.tif','Choose a reference image');
            if filename == 0
                return;
            end
            app.filename_GridRef=[filepath filename];
            % A new reference image invalidates any grid setup already in
            % progress (it was measured against the OLD image) -- reset
            % back to a blank state, same as ResetSettingsButtonPushed.
            GridSettingStatusChange(app, 0)


        end

        % Button pushed function: ChangeObjDistortionButton
        function ChangeObjDistortionButtonPushed(app, event)
            if app.debug
                % No known real lens-distortion reference to point at for
                % scripted testing -- behave as a cancelled picker, same
                % rationale as ChangeFlatfieldImageButtonPushed above.
                return;
            end
            [filename,filepath]=uigetfile('*.mat','Choose Lens Distortion Correction Reference');
            if filename == 0
                return;
            end
            
            filename=[filepath filename];
            app.filename_GeometricDistortion=filename;
        end

        % Button pushed function: CorrectImagesButton
        function CorrectImagesButtonPushed(app, event)
            if(app.ui_ApplyFF==false && app.ui_ApplyGC==false && app.ui_ApplyDC==false)
                return;
            end

            if(app.ui_ApplyGC==true && app.grid_SettingStatus~=4)
                % Without this, the loop below silently skips the grid
                % warp (its own check further down requires
                % grid_SettingStatus==4) while still naming every output
                % file "..._GC.tiff" -- misleadingly implying grid
                % correction was applied when it wasn't. Reachable e.g. by
                % checking Apply Grid Correction while the grid is ready,
                % then hitting Reset or loading a different/incomplete
                % settings file without unchecking it.
                uialert(app.ImageCorrectionDialogUIFigure, ...
                    ['Apply Grid Correction is checked, but the grid setup isn''t fully populated ' ...
                     '(Populate the Rest must finish first). Finish the grid setup or uncheck ' ...
                     'Apply Grid Correction before correcting images.'], 'Grid Correction Not Ready');
                return;
            end

            filepath=uigetdir('*.*','Choose folder for image correction');
            if filepath == 0
                return;
            end
            
            ProcessDirectory=filepath;
            files=dir(fullfile(ProcessDirectory,strcat('*.','tiff')));
            processImages=files;
            
            filename=[ProcessDirectory filesep processImages(1).name];
            file_info = imfinfo(filename);
            app.img_SizeZ = numel(file_info);
            nImages=length(processImages);

            app.ref_Image=imread(filename, 1);
            app.ref_Image=single(app.ref_Image);
            
            
            %% Setup Flatfieldimage
            if(app.ui_ApplyFF==true)
                try
                    FFImage=imread(app.filename_Flatfield, 1);
                catch ME
                    uialert(app.ImageCorrectionDialogUIFigure, ...
                        sprintf('Could not load the flatfield image ("%s"): %s', app.filename_Flatfield, ME.message), ...
                        'Flatfield Image Not Found');
                    return;
                end
                FFImage=single(FFImage);
                %select center region and calculate average intensity there
                FFImageSize=size(FFImage);
                % round() -- indexing with a non-integer (e.g. a height
                % that isn't a multiple of 4) errors outright; also fixed
                % the column lower-bound, which previously reused
                % FFImageSize(1) (height) instead of FFImageSize(2) (width).
                rowRange=round(FFImageSize(1)*0.25):round(FFImageSize(1)*0.75);
                colRange=round(FFImageSize(2)*0.25):round(FFImageSize(2)*0.75);
                CropFFImage=FFImage(rowRange, colRange);
                AvgInt=sum(sum(CropFFImage))/size(CropFFImage,1)/size(CropFFImage,2);
                %Normalize the Flatfield image
                FFImage=AvgInt./FFImage;
                FFImage(FFImage==Inf)=0;
            end
            
            %% Setup Grid Distortion Correction
            if(app.ui_ApplyGC==true && app.grid_SettingStatus==4)

                Z=zeros(1, app.grid_SizeZ);
                for iGrid=1:app.grid_SizeZ
                    Z(iGrid)=app.grid_PlaneStart+(iGrid-1)*app.grid_PlaneInterval;
                end

                % interpolate grid position for all slides
                Zz=1:1:app.img_SizeZ;
                grid_Position_Spline=spline(Z, app.grid_Position, Zz);

                [RA, worldPoints, squareSize]=GridTransformationInitialize(app, 1);  % Setup output world positions

                % Precompute every Z-slide's geometric transform ONCE here,
                % rather than inside the per-file loop below -- it depends
                % only on iZ (via grid_Position_Spline), never on which
                % file is being processed, so recomputing it per file was
                % doing N times the necessary fitgeotrans work for N files.
                % Shared with GridVerifyOverallCorrection's single-file
                % re-check, so both use exactly the same transform-fitting
                % logic as this batch path.
                gcTransformSet = GridBuildGCTransforms(app, grid_Position_Spline, worldPoints, squareSize, app.img_SizeZ);
            end
            
            if(app.ui_ApplyDC==true)
                try
                    load(app.filename_GeometricDistortion,"-mat",'lens_distortion_ref_K','d');
                catch ME
                    uialert(app.ImageCorrectionDialogUIFigure, ...
                        sprintf('Could not load the objective distortion correction file ("%s"): %s', ...
                        app.filename_GeometricDistortion, ME.message), 'Distortion Correction File Not Found');
                    return;
                end
                K=lens_distortion_ref_K;
                reference_slice_number=lens_distortion_ref_K{1}(:,4);
                
                polyOrder=2; % What Order polynomial to use for interpolating the reference points
                Kx_fitting=cell(6,1);
                Ky_fitting=cell(6,1);
                interpolatedPoints=zeros(6,2,app.img_SizeZ); % Will use interpolated points of the
                firstOrderPoly=@(z,m,b)m.*z+b;
                secondOrderPoly=@(z,a,b,c)a.*z.^2+b.*z+c;
                
                for K_Point_Number=1:6
                    if(polyOrder==1)
                        Kx_fitting{K_Point_Number}=polyfit(reference_slice_number,K{K_Point_Number}(:,1),1);
                        Ky_fitting{K_Point_Number}=polyfit(reference_slice_number,K{K_Point_Number}(:,2),1);
                        
                        interpolatedPoints(K_Point_Number,1,:)=...
                            firstOrderPoly(1:app.img_SizeZ,Kx_fitting{K_Point_Number}(1),Kx_fitting{K_Point_Number}(2));
                        interpolatedPoints(K_Point_Number,2,:)=...
                            firstOrderPoly(1:app.img_SizeZ,Ky_fitting{K_Point_Number}(1),Ky_fitting{K_Point_Number}(2));
                        %                         referencePoints(K_Point_Number,:)=K{K_Point_Number}(3,:);
                    elseif(polyOrder==2)
                        Kx_fitting{K_Point_Number}=polyfit(reference_slice_number,K{K_Point_Number}(:,1),2);
                        Ky_fitting{K_Point_Number}=polyfit(reference_slice_number,K{K_Point_Number}(:,2),2);
                        
                        interpolatedPoints(K_Point_Number,1,:)=...
                            secondOrderPoly(1:app.img_SizeZ,Kx_fitting{K_Point_Number}(1),Kx_fitting{K_Point_Number}(2),Kx_fitting{K_Point_Number}(3));
                        interpolatedPoints(K_Point_Number,2,:)=...
                            secondOrderPoly(1:app.img_SizeZ,Ky_fitting{K_Point_Number}(1),Ky_fitting{K_Point_Number}(2),Ky_fitting{K_Point_Number}(3));
                        %                         referencePoints(K_Point_Number,:)=K{K_Point_Number}(3,:);
                    end
                end
                
                sizeOutput=[900 900];
                d=mean(d);
                horizontalPadding=(sizeOutput(2)-d)/2;
                verticalPadding=(sizeOutput(1)-d*sqrt(3)/2)/2;
                referenceHexagon=[
                    horizontalPadding+1*(d/4),  verticalPadding;                % K1
                    horizontalPadding,          1*(d*sqrt(3)/4)+verticalPadding;% K2
                    horizontalPadding+1*(d/4),  2*(d*sqrt(3)/4)+verticalPadding;% K3
                    horizontalPadding+3*(d/4),  2*(d*sqrt(3)/4)+verticalPadding;% K4
                    horizontalPadding+4*(d/4),  1*(d*sqrt(3)/4)+verticalPadding;% K5
                    horizontalPadding+3*(d/4),  verticalPadding;                % K6
                    ];
                
                sizeOutput=[900 900];
                RA2=imref2d(sizeOutput,[1 900],[1 900]);
                
                switch app.ui_Style
                    case 'STV 0, All Points'
                        DC_ref=[K{1}(K{1}(:,3,:)==0,1:2,:);
                            K{2}(K{2}(:,3,:)==0,1:2,:);
                            K{3}(K{3}(:,3,:)==0,1:2,:);
                            K{4}(K{4}(:,3,:)==0,1:2,:);
                            K{5}(K{5}(:,3,:)==0,1:2,:);
                            K{6}(K{6}(:,3,:)==0,1:2,:)];
                    case 'STV 0, 4 points'
                        DC_ref=[K{2}(K{2}(:,3,:)==0,1:2,:);
                            K{3}(K{3}(:,3,:)==0,1:2,:);
                            K{5}(K{5}(:,3,:)==0,1:2,:);
                            K{6}(K{6}(:,3,:)==0,1:2,:)];
                        interpolatedPoints=interpolatedPoints([2,3,5,6],:,:);
                    case 'Force Hexagon'
                        DC_ref=referenceHexagon;
                end

                % Same reasoning as gcTformByZ above -- this only depends
                % on iZ (via interpolatedPoints), never on which file is
                % being processed, so precompute it once here instead of
                % inside the per-file loop.
                dcTformByZ=cell(1, app.img_SizeZ);
                for iZ=1:app.img_SizeZ
                    dcTformByZ{iZ}=fitgeotrans(interpolatedPoints(:,:,iZ),DC_ref,'affine');
                end
            end
            
            fig=app.ImageCorrectionDialogUIFigure;
            title='Please Wait';
            dlg=uiprogressdlg(fig, 'Title', title, 'Cancelable','on');
            
            for iImage=1:nImages
                
                msg=sprintf('Processing image %d / %d', iImage, nImages);
                loop_i_percent=(iImage-1)/nImages;
                dlg.Value=loop_i_percent;
                dlg.Message=msg;
                
                OutputDirectory = [ProcessDirectory filesep 'Processed'];
                if not(isfolder(OutputDirectory))
                    mkdir(OutputDirectory)
                end
                
                Input_filename=[ProcessDirectory filesep processImages(iImage).name];
                Output_filename=[OutputDirectory filesep processImages(iImage).name];

                % A single native Tiff object (seeking between frames via
                % setDirectory) replaces repeated imread(Input_filename, iZ)
                % calls below -- imread reopens and re-parses the whole IFD
                % chain from the start on every call, which makes reading a
                % large stack frame-by-frame effectively O(n^2); this opens
                % the input file once per image and seeks directly.
                tiffReaderIn = Tiff(Input_filename, 'r');
                
                filename_prefix=Output_filename;
                idx = find(ismember(filename_prefix,'.'),1,'last');
                if filename_prefix(idx) == '.'
                    filename_prefix(idx:end) = [];
                end
                
                filename_Flatfield_suffix='';
                filename_GC_suffix='';
                filename_DC_suffix='';
                
                if(app.ui_ApplyFF==true)
                    filename_Flatfield_suffix='_FF';
                end
                
                if(app.ui_ApplyGC==true && app.grid_SettingStatus==4)
                    % Matches the actual per-slide GC condition below --
                    % the early guard at the top of this function already
                    % prevents ui_ApplyGC/status from disagreeing in
                    % practice, but keeping this in sync avoids ever
                    % naming an output "_GC" when no grid warp ran.
                    filename_GC_suffix='_GC';
                end
                
                if(app.ui_ApplyDC==true)
                    filename_DC_suffix='_DC';
                end
                
                filename_suffix=[filename_Flatfield_suffix filename_GC_suffix filename_DC_suffix];
                t = Tiff([filename_prefix filename_suffix '.tiff'],'w');
                
                for iZ=1:app.img_SizeZ
                    loop_j_percent=1/nImages*(iZ/app.img_SizeZ);
                    dlg.Value=loop_i_percent+loop_j_percent;
                    
                    if dlg.CancelRequested
                        dlg.Message=sprintf('Finishing current image...');
                    end
                    
                    tiffReaderIn.setDirectory(iZ);
                    LocalrawImage=tiffReaderIn.read();
                    LocalrawImage=single(LocalrawImage);
                    
                    if(app.ui_ApplyFF==true)
                        LocalrawImage=LocalrawImage.*FFImage;
                    end
                    
                    if(app.ui_ApplyGC==true  && app.grid_SettingStatus==4)
                        % gcTransformSet was already fit once, above
                        % (outside this per-file loop) -- reused here for
                        % every file instead of refitting per file.
                        correctedImage=GridApplyGCTransform(app, gcTransformSet, LocalrawImage, RA, iZ);
                        OutputImage=round(correctedImage,2);
                    else
                        OutputImage=LocalrawImage;
                    end

                    if(app.ui_ApplyDC==true)
                        % Same precompute-once reuse as gcTformByZ above.
                        correctedImage=imwarp(OutputImage, dcTformByZ{iZ}, 'Outputview', RA2,'interp', 'nearest');
                        OutputImage=round(correctedImage,2);
                    end
                    
                    setTag(t,'Photometric',Tiff.Photometric.MinIsBlack);
                    setTag(t,'PlanarConfiguration',Tiff.PlanarConfiguration.Chunky);
                    setTag(t,'Orientation',Tiff.Orientation.TopLeft);
                    setTag(t,'BitsPerSample',32);
                    setTag(t,'SamplesPerPixel',1);
                    setTag(t,'Compression', Tiff.Compression.LZW);
                    setTag(t,'ImageLength',size(OutputImage,1));
                    setTag(t,'ImageWidth',size(OutputImage,2));
                    setTag(t,'SampleFormat', Tiff.SampleFormat.IEEEFP);
                    write(t, single(OutputImage));
                    
                    writeDirectory(t);

                end
                close(t);
                close(tiffReaderIn);
                if dlg.CancelRequested
                    break
                end
            end
            close(dlg);

        end

        % Value changed function: GridPlaneStartEditField
        function GridPlaneStartEditFieldValueChanged(app, event)
            % Start/End/Interval are interdependent (End = Start +
            % (SizeZ-1)*Interval): changing Start keeps the current END
            % slide fixed and recalculates Interval to match, rather than
            % silently shifting End too.
            oldEnd = app.grid_PlaneStart + (app.grid_SizeZ-1)*app.grid_PlaneInterval;
            app.grid_PlaneStart=event.Value;
            if app.grid_SizeZ > 1
                app.grid_PlaneInterval = max(1, round((oldEnd - app.grid_PlaneStart)/(app.grid_SizeZ-1)));
            end
            SetGridPlaneParameter(app);
        end

        % Value changed function: GridPlaneEndEditField (End is otherwise
        % a derived/display-only value -- see BuildViewModel's
        % gridPlaneEnd -- but is also directly editable: typing a new End
        % keeps Start fixed and recalculates Interval to match.)
        function GridPlaneEndEditFieldValueChanged(app, event)
            if app.grid_SizeZ > 1
                app.grid_PlaneInterval = max(1, round((event.Value - app.grid_PlaneStart)/(app.grid_SizeZ-1)));
            end
            SetGridPlaneParameter(app);
        end

        % Value changed function: GridSizeZEditField
        function GridSizeZEditFieldValueChanged(app, event)
            app.grid_SizeZ=event.Value;
            SetGridPlaneParameter(app);

        end

        % Value changed function: GridPlaneIntervalEditField
        function GridPlaneIntervalEditFieldValueChanged(app, event)
            app.grid_PlaneInterval=event.Value;
            SetGridPlaneParameter(app);

        end

        % Button pushed function: QuickSetupButton
        function QuickSetupButtonPushed(app, event)
            % Initialise, then detect+populate plane 1, fully
            % automatically -- no interactive confirm/drag dialog (that's
            % now a separate on-demand action, see AdjustGridOriginButton).
            % Only actually pauses for user interaction if auto-detect
            % fails outright and falls back to manual 4-point clicking,
            % since that's the one interaction that can't be avoided.
            GridInitialization(app);
            LoadReferenceImage(app);
            GridSettingStatusChange(app, 1);
            GridUpdatePlaneLabel(app);

            app.grid_PlaneCurrent=1;
            ChangeRefImagePlane(app);

            fig=app.ImageCorrectionDialogUIFigure;
            title='Please Wait';
            dlg=uiprogressdlg(fig, 'Title', title, 'Cancelable','off');
            msg=sprintf('Detecting grid lattice');
            dlg.Message=msg;

            useManual = ~app.grid_AutoDetectEnabled;
            latticeModel = [];
            if ~useManual
                [latticeModel, autoStatus] = GridAutoDetectLattice(app, app.ref_Image);
                GridLog(app, 'Plane 1: auto-detect status=%d (d1=%.2f d2=%.2f, rotation %.1f/%.1fdeg, confidence=%d)', ...
                    autoStatus, latticeModel.d1, latticeModel.d2, latticeModel.theta1, latticeModel.theta2, latticeModel.confidence);
                if autoStatus < 0
                    useManual = true;
                    GridLog(app, 'Plane 1: falling back to manual seeding.');
                end
            end

            if useManual
                EnterGridEditorMode(app);
                imshow(app.ref_Image, [0 1], 'Parent', app.GridAxes);
                app.GridAxes.XLim = [0.5, size(app.ref_Image,2)+0.5];
                app.GridAxes.YLim = [0.5, size(app.ref_Image,1)+0.5];

                if(app.debug==true && app.fig_Grid_InitHandleReady==false)
                    app.grid_Init_Position=zeros(4,2);
                    app.grid_Init_Position(1,:)=[233  340];
                    app.grid_Init_Position(2,:)=[236  380];
                    app.grid_Init_Position(3,:)=[277  373];
                    app.grid_Init_Position(4,:)=[277  332];
                    app.fig_Grid_InitHandleReady=true;
                end

                if(app.fig_Grid_InitHandleReady==false)
                    app.grid_Init_Position=zeros(4,2);
                    for i=1:4
                        app.fig_Grid_InitHandle{i}.handle = drawpoint(app.GridAxes);
                        try
                            app.fig_Grid_InitHandle{i}.handle.Tag=int2str(i);
                            addlistener(app.fig_Grid_InitHandle{i}.handle,'ROIMoved', @(varargin)GridInitPositionMoved(app, varargin));
                        catch
                            warning('Grid points are missing');
                            close(dlg);
                            return;
                        end
                        app.grid_Init_Position(i,:) = app.fig_Grid_InitHandle{i}.handle.Position;
                    end
                    app.fig_Grid_InitHandleReady=true;
                else
                    for i=1:4
                        app.fig_Grid_InitHandle{i}.handle = drawpoint(app.GridAxes, "Position",app.grid_Init_Position(i,:));
                        app.fig_Grid_InitHandle{i}.handle.Tag=int2str(i);
                        addlistener(app.fig_Grid_InitHandle{i}.handle,'ROIMoved', @(varargin)GridInitPositionMoved(app, varargin));
                    end
                end

                latticeModel = GridLatticeFromManualPoints(app);
            end

            % Must be set BEFORE GridOptimizePlaneUntilConverged: its 2nd+
            % pass reseeds via GridLatticeFromSurface, which reads
            % app.grid_LatticeModel{plane} internally.
            app.grid_LatticeModel{1} = latticeModel;

            planeTimer = tic;
            dlg.Message = 'Refining grid crossings';
            if app.ui_OptimizeGrid
                GridOptimizePlaneUntilConverged(app, 1, latticeModel, max(app.grid_RefinementPasses,4));
            else
                GridPlaceRawLatticePositions(app, 1, latticeModel);
            end
            GridChangeDisplayPlane(app);
            % Plane 1 has no prior trend to compare against (trust rests
            % on point-level quality alone) -- it's also the one plane the
            % user can directly verify/correct via Adjust Grid Origin
            % before anything else runs, so it anchors every later
            % plane's Z-trend.
            GridUpdatePlaneTrust(app, 1);
            GridLog(app, 'Plane 1: done in %.2fs', toc(planeTimer));
            GridSettingStatusChange(app, 3);

            close(dlg);
        end

        % Button pushed function: AdjustGridOriginButton
        function AdjustGridOriginButtonPushed(app, event)
            % On-demand version of the origin confirm/drag interaction --
            % no longer runs automatically during setup. Always operates
            % on plane 1, regardless of whichever plane is currently
            % displayed: plane 1 is the fixed origin reference every
            % other plane's phase/alignment is checked against
            % (GridAlignPlanePhase always compares to plane 1), so it's
            % the only plane where adjusting the origin is meaningful --
            % switches the display to plane 1 first if a different plane
            % was being viewed.
            plane = 1;
            app.grid_PlaneCurrent = plane;
            GridUpdatePlaneLabel(app);
            if numel(app.grid_LatticeModel) < plane || isempty(app.grid_LatticeModel{plane})
                uialert(app.ImageCorrectionDialogUIFigure, ...
                    sprintf('No lattice model available for plane %d yet.', plane), 'Cannot Adjust Origin');
                return;
            end
            ChangeRefImagePlane(app);
            ConfirmGridOriginAndRefine(app, plane, app.grid_LatticeModel{plane});
        end

        % Button pushed function: PopulatetherestButton
        function PopulatetherestButtonPushed(app, event)
            fig=app.ImageCorrectionDialogUIFigure;
            title='Grid Optimization';
            dlg=uiprogressdlg(fig, 'Title', title, 'Cancelable','on');

            for i=2:app.grid_SizeZ
                msg=sprintf('Working on Grid Plane %d / %d', i, app.grid_SizeZ);
                progress_bar=i/(app.grid_SizeZ);
                dlg.Value=progress_bar;
                dlg.Message=msg;

                app.grid_PlaneCurrent=i;
                GridLog(app, 'Plane %d/%d: loading image...', i, app.grid_SizeZ);

                ChangeRefImagePlane(app);

                planeTimer = tic;
                if app.ui_OptimizeGrid
                    % GridSeedPlaneLattice traces this plane's lattice from
                    % already-trusted previous planes' smooth Z-trend
                    % rather than trusting a fresh independent FFT reading
                    % outright (see its header comment for why -- FFT peak
                    % selection can be confidently wrong), bridging via
                    % disposable probe samples when the gap looks too
                    % large, and falling back to FFT only as a genuine
                    % last resort. As a side effect it also performs this
                    % plane's actual "light" optimization pass (it needs
                    % to, to empirically judge whether a candidate seed is
                    % good enough), so nothing further is needed here --
                    % just as before, this is only ONE light pass; the full
                    % Z-correlation + thorough refinement below is
                    % unchanged.
                    [latticeModel, seedSource] = GridSeedPlaneLattice(app, i);
                    app.grid_LatticeModel{i} = latticeModel;
                    GridLog(app, 'Plane %d: lattice seeded from %s (d1=%.2f d2=%.2f, rotation %.1f/%.1fdeg).', ...
                        i, seedSource, latticeModel.d1, latticeModel.d2, latticeModel.theta1, latticeModel.theta2);
                    GridCheckPlaneContinuity(app, i);
                    GridUpdatePlaneTrust(app, i);
                    if startsWith(seedSource, 'unresolved-')
                        % GridSeedPlaneLattice already exhausted every
                        % tier (trend, FFT hard-reset, bridging) without
                        % ever clearing the quality floor -- never let a
                        % plane we already know is unresolved feed later
                        % planes' trend fits.
                        app.grid_LatticeModel{i}.trusted = false;
                    end
                else
                    % "Optimize Grid Crossings" unchecked: fast, unrefined
                    % preview only -- keep this path simple (fresh FFT per
                    % plane, same fallback as before) since there's no
                    % optimization pass here to empirically validate a
                    % traced seed against anyway.
                    [latticeModel, autoStatus] = GridAutoDetectLattice(app, app.ref_Image);
                    if autoStatus < 0
                        latticeModel = app.grid_LatticeModel{i-1};
                        warnState = warning('off','backtrace'); % keep the message, drop the noisy call-stack lines
                        warning('GridCorrection:AutoDetectFailed', ...
                            ['Automatic grid detection failed on plane %d; reusing plane %d''s ' ...
                             'lattice. Please visually re-check this plane.'], i, i-1);
                        warning(warnState);
                    else
                        latticeModel = GridAlignPlanePhase(app, i, latticeModel);
                    end
                    app.grid_LatticeModel{i} = latticeModel;
                    GridCheckPlaneContinuity(app, i);
                    GridPlaceRawLatticePositions(app, i, latticeModel);
                end
                GridLog(app, 'Plane %d/%d: initial pass done in %.2fs', i, app.grid_SizeZ, toc(planeTimer));
                if dlg.CancelRequested
                    break
                end
            end

            if app.ui_OptimizeGrid && ~dlg.CancelRequested
                % Correlate crossing positions across Z planes (mirrors the
                % within-plane XY smoothing above) now that every plane has
                % at least one real measurement.
                dlg.Message = 'Correlating grid positions across planes (Z)';
                GridLog(app, 'Correlating grid positions across planes (Z)...');
                GridFitZSmoothing(app);
                GridLog(app, 'Z-correlation done.');

                % NOW do the thorough refinement, on EVERY plane (plane 1
                % included, in case Z-correlation replaced any of its
                % points too), seeded from wherever each point currently
                % stands -- its own light measurement, or the
                % trend-corrected value filled in above. A trend fill is
                % never trusted outright: it's just a much better
                % starting guess for a fresh, independent local
                % Gaussian-dip search than the plane's raw uniform
                % lattice would have been, so points that couldn't
                % converge on their own often can once seeded this way.
                GridLog(app, 'Refining every plane again after Z-correlation...');
                for i = 1:app.grid_SizeZ
                    dlg.Message = sprintf('Refining plane %d / %d (post-correlation)', i, app.grid_SizeZ);
                    dlg.Value = i/app.grid_SizeZ;
                    planeTimer = tic;
                    app.grid_PlaneCurrent = i;
                    ChangeRefImagePlane(app); % GridPositionOptimize reads app.ref_Image, not the plane index
                    seedModel = GridLatticeFromCurrentPositions(app, i);
                    GridOptimizePlaneUntilConverged(app, i, seedModel, max(app.grid_RefinementPasses,4));
                    % Re-evaluate trust now that this plane has had its
                    % thorough (not just light) refinement pass -- quality
                    % may have improved, so a plane that couldn't be fully
                    % trusted during the initial per-plane loop might
                    % qualify now (or vice versa).
                    GridUpdatePlaneTrust(app, i);
                    GridLog(app, 'Plane %d/%d: post-correlation refine done in %.2fs', i, app.grid_SizeZ, toc(planeTimer));
                    if dlg.CancelRequested
                        break
                    end
                end
            end

            close(dlg);
            % Return to plane 1 so the displayed count matches the still-
            % displayed figure (the figure isn't redrawn here), and refresh
            % it to show plane 1's final, fully-processed positions.
            app.grid_PlaneCurrent = 1;
            GridUpdatePlaneLabel(app);
            GridSettingStatusChange(app, 4);
            GridChangeDisplayPlane(app);


        end

        % Button pushed function: OptimizePlaneButton
        function OptimizePlaneButtonPushed(app, event)
            % Re-run optimization (independent local refinement + robust
            % global surface fit) on whichever plane is currently
            % displayed -- available any time a plane has been populated,
            % regardless of whether "Optimize Grid Crossings" was checked
            % when it was first populated, and regardless of any manual
            % nudges made since. Seeded from the CURRENT positions, so
            % running it repeatedly performs additional refinement passes.
            plane = app.grid_PlaneCurrent;

            fig = app.ImageCorrectionDialogUIFigure;
            dlg = uiprogressdlg(fig, 'Title', 'Please Wait', ...
                'Message', sprintf('Optimizing plane %d', plane), 'Cancelable','off');

            ChangeRefImagePlane(app);

            try
                latticeModel = GridLatticeFromCurrentPositions(app, plane);
            catch ME
                close(dlg);
                uialert(fig, ME.message, 'Cannot Optimize Plane');
                return;
            end

            GridOptimizePlaneUntilConverged(app, plane, latticeModel, max(app.grid_RefinementPasses,4));

            GridChangeDisplayPlane(app);
            close(dlg);
        end

        % Button pushed function: GridDisplayFirstPlane
        function GridDisplayFirstPlaneButtonPushed(app, event)
            app.grid_PlaneCurrent=1;
            GridUpdatePlaneLabel(app);
            GridChangeDisplayPlane(app);
        end

        % Button pushed function: GridDisplayLastPlane
        function GridDisplayLastPlaneButtonPushed(app, event)
            app.grid_PlaneCurrent=app.grid_SizeZ;
            GridUpdatePlaneLabel(app);
            GridChangeDisplayPlane(app);
        end

        % Button pushed function: GridDisplayPrevPlane
        function GridDisplayPrevPlaneButtonPushed(app, event)
            app.grid_PlaneCurrent=app.grid_PlaneCurrent-1;
            if(app.grid_PlaneCurrent<1) 
                app.grid_PlaneCurrent=1;
            end
            GridUpdatePlaneLabel(app);
            GridChangeDisplayPlane(app);
        end

        % Button pushed function: GridDisplayNextPlane
        function GridDisplayNextPlaneButtonPushed(app, event)
            app.grid_PlaneCurrent=app.grid_PlaneCurrent+1;
            if(app.grid_PlaneCurrent>app.grid_SizeZ)
                app.grid_PlaneCurrent=app.grid_SizeZ;
            end
            GridUpdatePlaneLabel(app);
            GridChangeDisplayPlane(app);
        end

        % Value changed function: GridPlaneAveragingEditField
        function GridPlaneAveragingEditFieldValueChanged(app, event)
            app.grid_PlaneAveraging = event.Value;

        end

        % Value changed function: GridSizeXEditField
        function GridSizeXEditFieldValueChanged(app, event)
            app.grid_SizeX = event.Value;

        end

        % Value changed function: GridSizeYEditField
        function GridSizeYEditFieldValueChanged(app, event)
            app.grid_SizeY = event.Value;

        end

        % Button pushed function: CorrectionTestButton
        function CorrectionTestButtonPushed(app, event)
            DistortionCorrectionTest(app);
        end

        % Button pushed function: ResetSettingsButton
        function ResetSettingsButtonPushed(app, event)
            GridSettingStatusChange(app, 0);
            % Back to a blank state: there is nothing left worth saving,
            % so closing straight after a reset shouldn't prompt.
            GridMarkStateSaved(app);

        end

        % Value changed function: OutputShiftXEditField
        function OutputShiftXEditFieldValueChanged(app, event)
            app.image_OutputShiftX = event.Value;

        end

        % Value changed function: OutputShiftYEditField
        function OutputShiftYEditFieldValueChanged(app, event)
            app.image_OutputShiftY = event.Value;

        end

        % Value changed function: ShowFittingFigureCheckBox
        function ShowFittingFigureCheckBoxValueChanged(app, event)
            app.debugPlot = event.Value;
        end

        % --- V5 HTML dashboard: view model + one-liner field handlers --
        % Page navigation itself (Home <-> Flatfield/Grid/Objective) is
        % pure client-side JS now (see BuildMainUIHTML) -- MATLAB only
        % needs to know field VALUES, never which page is on screen.

        % Gathers everything the HTML UI needs to render into one struct
        % and pushes it to the uihtml component. Called after every
        % action the dispatcher (MainUIDataChanged) handles, and once at
        % startup, so the page is always showing current app state.
        function model = BuildViewModel(app)
            if strcmp(app.filename_Flatfield, 'none')
                ffStatus = 'Not configured';
                ffName = '';
            else
                [~, n, e] = fileparts(app.filename_Flatfield);
                ffStatus = [n e];
                ffName = [n e];
            end

            % Status values in play (see GridSettingStatusChange): 0 blank,
            % 1 reference image loaded, 3 first plane fitted (set by
            % QuickSetupButtonPushed), 4 all planes done (set by
            % PopulatetherestButtonPushed) -- 2 is reserved but currently
            % unused by any caller, so it's folded into the "first plane"
            % message rather than misreported as fully configured.
            if app.grid_SettingStatus < 1
                gridStatus = 'Not configured';
            elseif app.grid_SettingStatus == 1
                gridStatus = 'Reference image loaded, not yet populated';
            elseif app.grid_SettingStatus < 4
                gridStatus = 'First plane fitted (populate the rest to finish)';
            else
                gridStatus = sprintf('Configured (%d planes)', size(app.grid_Position, 3));
            end

            if strcmp(app.filename_GeometricDistortion, 'none')
                objStatus = 'Not configured';
                objName = '';
            else
                [~, n, e] = fileparts(app.filename_GeometricDistortion);
                objStatus = [n e];
                objName = [n e];
            end

            if strcmp(app.filename_GridRef, 'none')
                gridRefName = '';
            else
                [~, n, e] = fileparts(app.filename_GridRef);
                gridRefName = [n e];
            end

            if strcmp(app.filename_CurrentSettings, 'none')
                currentSettingsName = '';
            else
                [~, n, e] = fileparts(app.filename_CurrentSettings);
                currentSettingsName = [n e];
            end

            model = struct( ...
                'ffStatus', ffStatus, 'ffName', ffName, 'ffFullPath', app.filename_Flatfield, ...
                'gridStatus', gridStatus, 'gridRefName', gridRefName, 'gridRefFullPath', app.filename_GridRef, ...
                'objStatus', objStatus, 'objName', objName, 'objFullPath', app.filename_GeometricDistortion, ...
                'currentSettingsName', currentSettingsName, 'currentSettingsFullPath', app.filename_CurrentSettings, ...
                'gridSizeX', app.grid_SizeX, 'gridSizeY', app.grid_SizeY, 'gridSizeZ', app.grid_SizeZ, ...
                'gridPlaneStart', app.grid_PlaneStart, 'gridPlaneAveraging', app.grid_PlaneAveraging, ...
                'gridPlaneInterval', app.grid_PlaneInterval, ...
                'gridPlaneEnd', app.grid_PlaneStart+(app.grid_SizeZ-1)*app.grid_PlaneInterval, ...
                'verboseOutput', app.ui_VerboseOutput, 'showFittingFigure', app.debugPlot, ...
                'optimizeGrid', app.ui_OptimizeGrid, 'transformationMethod', app.ui_TransformationMethod, ...
                'style', app.ui_Style, ...
                'outputShiftX', app.image_OutputShiftX, 'outputShiftY', app.image_OutputShiftY, ...
                'gridFieldsEnabled', app.ui_GridFieldsEnabled, 'quickSetupEnabled', app.ui_QuickSetupEnabled, ...
                'applyFF', app.ui_ApplyFF, 'applyGC', app.ui_ApplyGC, 'applyDC', app.ui_ApplyDC, ...
                'applyFFEnabled', ~strcmp(app.filename_Flatfield,'none'), ...
                'applyGCEnabled', app.ui_ApplyGCEnabled, ...
                'applyDCEnabled', ~strcmp(app.filename_GeometricDistortion,'none'), ...
                'viewEditorEnabled', app.ui_ViewEditorEnabled, ...
                'navigateToken', app.ui_MainUINavigateToken, 'navigateTo', app.ui_MainUINavigateTo);
        end

        function PushViewModel(app)
            app.MainUI.Data = BuildViewModel(app);
        end

        % Single entry point for every event the HTML UI sends. JS always
        % sends {action, ...payload}; this dispatches to the SAME
        % existing button/field callback functions the native V4
        % uicontrols used to invoke, then refreshes the whole view model
        % once at the end so the HTML always reflects the latest state
        % (cheaper and far less error-prone than pushing partial updates
        % from every single case below).
        function MainUIDataChanged(app, event)
            data = event.Data;
            switch data.action
                case 'chooseFlatfield'
                    ChangeFlatfieldImageButtonPushed(app, []);
                case 'chooseObjective'
                    ChangeObjDistortionButtonPushed(app, []);
                case 'chooseGridRef'
                    ChangeRefImageButtonPushed(app, []);
                case 'setGridSizeX'
                    GridSizeXEditFieldValueChanged(app, struct('Value', data.value));
                case 'setGridSizeY'
                    GridSizeYEditFieldValueChanged(app, struct('Value', data.value));
                case 'setGridSizeZ'
                    GridSizeZEditFieldValueChanged(app, struct('Value', data.value));
                case 'setGridPlaneStart'
                    GridPlaneStartEditFieldValueChanged(app, struct('Value', data.value));
                case 'setGridPlaneEnd'
                    GridPlaneEndEditFieldValueChanged(app, struct('Value', data.value));
                case 'setGridPlaneAveraging'
                    GridPlaneAveragingEditFieldValueChanged(app, struct('Value', data.value));
                case 'setGridPlaneInterval'
                    GridPlaneIntervalEditFieldValueChanged(app, struct('Value', data.value));
                case 'setOutputShiftX'
                    OutputShiftXEditFieldValueChanged(app, struct('Value', data.value));
                case 'setOutputShiftY'
                    OutputShiftYEditFieldValueChanged(app, struct('Value', data.value));
                case 'setVerboseOutput'
                    app.ui_VerboseOutput = data.value;
                case 'setShowFittingFigure'
                    ShowFittingFigureCheckBoxValueChanged(app, struct('Value', data.value));
                case 'setOptimizeGrid'
                    app.ui_OptimizeGrid = data.value;
                case 'setTransformationMethod'
                    app.ui_TransformationMethod = data.value;
                case 'setStyle'
                    app.ui_Style = data.value;
                case 'setApplyFF'
                    app.ui_ApplyFF = data.value;
                case 'setApplyGC'
                    app.ui_ApplyGC = data.value;
                case 'setApplyDC'
                    app.ui_ApplyDC = data.value;
                case 'quickSetup'
                    % Hard-disabled (see ui_QuickSetupEnabled) once
                    % anything is set up, so no confirm-before-reinit
                    % guard is needed here -- unlike populateRest below,
                    % which stays clickable throughout.
                    if app.ui_QuickSetupEnabled
                        QuickSetupButtonPushed(app, []);
                    end
                case 'viewGridEditor'
                    % Reopens the grid-point editor on the already-
                    % populated grid without re-running Quick Setup's
                    % detection -- necessary now that the editor lives in
                    % this same window rather than a separate figure(1)
                    % the user could just click back to.
                    if app.ui_ViewEditorEnabled
                        GridChangeDisplayPlane(app);
                    end
                case 'resetSettings'
                    ResetSettingsButtonPushed(app, []);
                case 'loadSettings'
                    LoadSettingsButtonPushed(app, []);
                case 'saveSettings'
                    SaveSettingsButtonPushed(app, []);
                case 'correctImages'
                    CorrectImagesButtonPushed(app, []);
            end
            PushViewModel(app);
        end

        % --- V6 grid-editor sidebar (GridSidebarUI): view model + dispatcher ---

        function model = BuildGridEditorViewModel(app)
            model = struct( ...
                'planeCurrent', app.grid_PlaneCurrent, 'planeTotal', app.grid_SizeZ, ...
                'sidebarMode', app.ui_GridSidebarMode, ...
                'originConfirmInfo', app.ui_GridOriginConfirmInfo, ...
                'instructionsText', GridNormalInstructionsText(app), ...
                'transformationMethod', app.ui_TransformationMethod, ...
                'nav', app.ui_GridNav, 'allPlanesReady', app.grid_SettingStatus>=4);
        end

        function PushGridEditorViewModel(app)
            app.GridSidebarUI.Data = BuildGridEditorViewModel(app);
        end

        % Single entry point for every event GridSidebarUI sends -- same
        % pattern as MainUIDataChanged, dispatching to the same existing
        % nav/action callback functions the old figure(1) uicontrols
        % used to invoke.
        function GridSidebarDataChanged(app, event)
            data = event.Data;
            switch data.action
                case 'first'
                    GridDisplayFirstPlaneButtonPushed(app, []);
                case 'prev'
                    GridDisplayPrevPlaneButtonPushed(app, []);
                case 'next'
                    GridDisplayNextPlaneButtonPushed(app, []);
                case 'last'
                    GridDisplayLastPlaneButtonPushed(app, []);
                case 'optimizePlane'
                    OptimizePlaneButtonPushed(app, []);
                case 'setTransformationMethod'
                    % Same setting the dashboard's own selector drives --
                    % duplicated here so a model can be switched and
                    % re-tested without leaving the grid editor. Push the
                    % dashboard view model too so its selector doesn't go
                    % stale behind this one.
                    app.ui_TransformationMethod = data.value;
                    PushViewModel(app);
                case 'correctionTest'
                    CorrectionTestButtonPushed(app, []);
                case 'compareAllModels'
                    GridCompareAllModels(app);
                case 'adjustOrigin'
                    % This single button is either "Adjust Grid Origin"
                    % or (while ui_GridSidebarMode=='originConfirm')
                    % "Confirm Origin" -- same repurposing the old
                    % annotation/uicontrol sidebar did, just driven by
                    % the view model instead of literally renaming a
                    % uicontrol's String/Callback.
                    if strcmp(app.ui_GridSidebarMode, 'originConfirm')
                        GridConfirmOriginClicked(app);
                    else
                        AdjustGridOriginButtonPushed(app, []);
                    end
                case 'populateRest'
                    if ConfirmGridReinit(app, 'Populate the Rest', ...
                            're-process every plane except plane 1 and discard any manual adjustments made on them')
                        PopulatetherestButtonPushed(app, []);
                    end
                case 'backToDashboard'
                    ExitGridEditorMode(app);
                case 'finish'
                    % Unlike "Back to Grid Setup" (which just returns to
                    % whichever dashboard page was showing before), Finish
                    % explicitly lands on Home -- set the navigate
                    % request BEFORE exiting so ExitGridEditorMode's own
                    % PushViewModel call carries it.
                    app.ui_MainUINavigateToken = app.ui_MainUINavigateToken + 1;
                    app.ui_MainUINavigateTo = 'home';
                    ExitGridEditorMode(app);
                case 'refineAllPlanes'
                    GridRefineAllPlanes(app);
                case 'verifyOverallCorrection'
                    GridVerifyOverallCorrection(app);
            end
            if app.ui_GridEditorMode
                PushGridEditorViewModel(app);
            end
        end

        function fingerprint = GridSettingsFingerprint(app)
            % Snapshot of everything SaveSettingsButtonPushed persists, so
            % "are there unsaved changes?" can be answered by comparing
            % the current state against the last saved/loaded one.
            %
            % Deliberately a comparison rather than a dirty flag set at
            % each mutation site: grid_Position alone is written from a
            % dozen places (drag, right-click refine, Quick Setup,
            % Populate the Rest, Optimize This Plane, Refine All Planes,
            % Adjust Origin, the Z-smoothing and surface-fit passes), and
            % a flag that misses any one of them silently loses the
            % user's work at close time.
            %
            % grid_Info and grid_LatticeModel are left out on purpose:
            % both are derived from the positions and settings below, so
            % anything that meaningfully changes them changes these too.
            fingerprint = {app.grid_Position, app.grid_Init_Position, ...
                app.grid_SizeX, app.grid_SizeY, app.grid_SizeZ, ...
                app.grid_PlaneStart, app.grid_PlaneAveraging, app.grid_PlaneInterval, ...
                app.grid_SettingStatus, app.ui_TransformationMethod, ...
                app.filename_GridRef, app.filename_Flatfield, app.filename_GeometricDistortion, ...
                app.ui_ApplyFF, app.ui_ApplyGC, app.ui_ApplyDC, ...
                app.image_OutputShiftX, app.image_OutputShiftY, ...
                app.grid_AutoDetectEnabled, app.ui_OptimizeGrid, app.grid_RefinementPasses};
        end

        function GridMarkStateSaved(app)
            % Call whenever the in-memory state and the on-disk settings
            % agree: after a save, after a load, after a reset, and at
            % startup.
            app.ui_SavedStateFingerprint = GridSettingsFingerprint(app);
        end

        function changed = GridHasUnsavedChanges(app)
            changed = ~isequal(GridSettingsFingerprint(app), app.ui_SavedStateFingerprint);
        end

        function ok = ConfirmGridReinit(app, actionLabel, warningDetail)
            % Populate the Rest re-runs detection from scratch on every
            % plane past the first, silently discarding whatever is
            % already there. Confirm before proceeding rather than
            % disabling the button outright, so a deliberate re-run
            % (e.g. after picking a different reference image) stays
            % possible without a trip back to Reset Settings.
            %
            % Only worth asking once those planes actually hold something
            % to lose, i.e. status 4 (Populate the Rest has completed).
            % At status 3 only plane 1 is populated -- that's the normal
            % first-time path into this button, where there is nothing to
            % discard and a warning would just be noise. (Quick Setup is
            % hard-disabled outside status 0 rather than confirm-guarded,
            % so it never reaches here.)
            if app.grid_SettingStatus < 4
                ok = true;
                return;
            end
            if app.debug
                % Automated/headless testing can't click a modal dialog --
                % same rationale as ChangeRefImageButtonPushed's hardcoded
                % path bypass. Always proceed, since a scripted test run
                % deliberately means to re-run from scratch.
                ok = true;
                return;
            end
            selection = uiconfirm(app.ImageCorrectionDialogUIFigure, ...
                sprintf('%s will %s. This cannot be undone. Continue?', actionLabel, warningDetail), ...
                'Re-run Grid Setup?', 'Options', {'Continue','Cancel'}, 'DefaultOption', 2, 'Icon', 'warning');
            ok = strcmp(selection, 'Continue');
        end

        function html = BuildMainUIHTML(~)
            % The entire V6 dashboard/setup UI as one HTML/CSS/JS
            % single-page app. Built as a cell array of lines (one MATLAB
            % char row-vector per line) rather than one giant string --
            % far easier to review/edit than escaped multi-line literals.
            lines = {
                '<!DOCTYPE html>'
                '<html>'
                '<head>'
                '<meta charset="UTF-8">'
                '<style>'
                '  :root {'
                '    --bg: #f3f4f6;'
                '    --card-bg: #ffffff;'
                '    --border: #dde1e6;'
                '    --text: #1f2328;'
                '    --text-secondary: #616873;'
                '    --accent: #0072bd;'
                '    --accent-hover: #005a94;'
                '    --ok: #1a7f37;'
                '    --muted: #8a919b;'
                '  }'
                '  * { box-sizing: border-box; }'
                '  html, body {'
                '    margin: 0; padding: 0; height: 100%;'
                '    background: var(--bg);'
                '    color: var(--text);'
                '    font-family: -apple-system, "Segoe UI", Helvetica, Arial, sans-serif;'
                '    font-size: 13px;'
                '  }'
                '  .topbar {'
                '    display: flex; align-items: center; gap: 10px;'
                '    padding: 10px 18px;'
                '    background: var(--card-bg);'
                '    border-bottom: 1px solid var(--border);'
                '  }'
                '  .topbar .back-btn {'
                '    display: none;'
                '    border: 1px solid var(--accent); background: #fff; cursor: pointer;'
                '    color: var(--accent); font-size: 13px; font-weight: 700;'
                '    padding: 6px 12px;'
                '    border-radius: 6px;'
                '  }'
                '  .topbar .back-btn:hover { background: #eef6fc; color: var(--accent-hover); border-color: var(--accent-hover); }'
                '  .topbar .title { font-size: 15px; font-weight: 700; }'
                '  .content { padding: 12px 18px 18px; max-width: 640px; margin: 0 auto; }'
                '  .page { display: none; }'
                '  .page.active { display: block; }'
                '  .instructions {'
                '    color: var(--text-secondary);'
                '    line-height: 1.4;'
                '    margin: 0 0 14px;'
                '  }'
                '  .card {'
                '    background: var(--card-bg);'
                '    border: 1px solid var(--border);'
                '    border-radius: 10px;'
                '    padding: 12px 16px;'
                '    margin-bottom: 12px;'
                '  }'
                '  .card h3 {'
                '    margin: 0 0 8px;'
                '    font-size: 12.5px;'
                '    font-weight: 700;'
                '    color: var(--text);'
                '  }'
                '  .step-row {'
                '    display: flex; align-items: center; justify-content: space-between;'
                '    gap: 12px;'
                '    padding: 7px 0;'
                '    border-bottom: 1px solid var(--border);'
                '  }'
                '  .step-row:last-child { border-bottom: none; }'
                '  .step-row .step-label { font-weight: 600; }'
                '  .step-row .step-status { color: var(--text-secondary); font-size: 12px; margin-top: 1px; }'
                '  .step-row .step-status.configured { color: var(--ok); }'
                '  .btn {'
                '    border: 1px solid var(--accent);'
                '    background: var(--accent);'
                '    color: #fff;'
                '    border-radius: 6px;'
                '    padding: 6px 12px;'
                '    font-size: 12.5px;'
                '    font-weight: 600;'
                '    cursor: pointer;'
                '    white-space: nowrap;'
                '  }'
                '  .btn:hover { background: var(--accent-hover); border-color: var(--accent-hover); }'
                '  .btn.secondary {'
                '    background: #fff; color: var(--accent);'
                '  }'
                '  .btn.secondary:hover { background: #eef6fc; }'
                '  .btn:disabled {'
                '    background: #e7e9ec; border-color: #e7e9ec; color: var(--muted); cursor: not-allowed;'
                '  }'
                '  .btn.big {'
                '    padding: 11px 18px; font-size: 13.5px; width: 100%;'
                '  }'
                '  .filerow {'
                '    display: flex; align-items: center; justify-content: space-between; gap: 12px;'
                '  }'
                '  .filename {'
                '    color: var(--accent);'
                '    font-size: 12.5px;'
                '    overflow: hidden; text-overflow: ellipsis; white-space: nowrap;'
                '    flex: 1;'
                '  }'
                '  .filename.empty { color: var(--muted); font-style: italic; }'
                '  .field-grid {'
                '    display: grid; grid-template-columns: 1fr auto; row-gap: 7px; column-gap: 10px;'
                '    align-items: center;'
                '  }'
                '  .field-grid label { color: var(--text); }'
                '  .field-grid .hint { color: var(--muted); font-size: 11px; display: block; margin-top: 1px; }'
                '  input[type=number], select {'
                '    border: 1px solid var(--border);'
                '    border-radius: 6px;'
                '    padding: 5px 7px;'
                '    font-size: 12.5px;'
                '    width: 90px;'
                '    background: #fff;'
                '    color: var(--text);'
                '  }'
                '  select { width: auto; min-width: 140px; }'
                '  input:disabled, select:disabled { background: #f1f2f4; color: var(--muted); }'
                '  .checkbox-row {'
                '    display: flex; align-items: center; gap: 8px; padding: 4px 0;'
                '  }'
                '  .checkbox-row label { cursor: pointer; }'
                '  .checkbox-row input[type=checkbox] { width: 15px; height: 15px; cursor: pointer; }'
                '  .checkbox-row.disabled label { color: var(--muted); }'
                '  .divider { height: 1px; background: var(--border); margin: 10px 0; }'
                '</style>'
                '</head>'
                '<body>'
                ''
                '<div class="topbar">'
                '  <button class="back-btn" id="backBtn" onclick="showPage(''home'')">&larr; Back</button>'
                '  <div class="title" id="pageTitle">Image Distortion Correction</div>'
                '</div>'
                ''
                '<div class="content">'
                ''
                '  <!-- ============ HOME ============ -->'
                '  <div class="page active" id="page-home">'
                '    <p class="instructions">'
                '      Set up each correction step below (Flatfield, Grid, Objective), then use Run Correction'
                '      to process every image in a folder. Once a grid and/or objective calibration is set up,'
                '      save it below so this setup only needs to be done once.'
                '    </p>'
                ''
                '    <div class="card">'
                '      <h3>Setup Steps</h3>'
                '      <div class="step-row">'
                '        <div>'
                '          <div class="step-label">Flatfield</div>'
                '          <div class="step-status" id="ffStatus">Not configured</div>'
                '        </div>'
                '        <button class="btn secondary" onclick="showPage(''flatfield'')">Set Up</button>'
                '      </div>'
                '      <div class="step-row">'
                '        <div>'
                '          <div class="step-label">Grid</div>'
                '          <div class="step-status" id="gridStatus">Not configured</div>'
                '        </div>'
                '        <button class="btn secondary" onclick="showPage(''grid'')">Set Up</button>'
                '      </div>'
                '      <div class="step-row">'
                '        <div>'
                '          <div class="step-label">Objective</div>'
                '          <div class="step-status" id="objStatus">Not configured</div>'
                '        </div>'
                '        <button class="btn secondary" onclick="showPage(''objective'')">Set Up</button>'
                '      </div>'
                '    </div>'
                ''
                '    <div class="card">'
                '      <h3>Settings</h3>'
                '      <div class="filerow" style="margin-bottom:8px">'
                '        <span class="filename empty" id="currentSettingsName">none</span>'
                '      </div>'
                '      <div style="display:flex; gap:8px;">'
                '        <button class="btn secondary" style="flex:1" onclick="sendAction(''loadSettings'')">Load Settings</button>'
                '        <button class="btn secondary" style="flex:1" onclick="sendAction(''saveSettings'')">Save Settings</button>'
                '      </div>'
                '    </div>'
                ''
                '    <div class="card">'
                '      <h3>Run Correction</h3>'
                '      <div class="checkbox-row" id="applyFFRow">'
                '        <input type="checkbox" id="applyFF" onchange="sendAction(''setApplyFF'', this.checked)">'
                '        <label for="applyFF">Apply Flatfield</label>'
                '      </div>'
                '      <div class="checkbox-row" id="applyGCRow">'
                '        <input type="checkbox" id="applyGC" onchange="sendAction(''setApplyGC'', this.checked)">'
                '        <label for="applyGC">Apply Grid Distortion Correction</label>'
                '      </div>'
                '      <div class="checkbox-row" id="applyDCRow">'
                '        <input type="checkbox" id="applyDC" onchange="sendAction(''setApplyDC'', this.checked)">'
                '        <label for="applyDC">Apply Objective Distortion Correction</label>'
                '      </div>'
                '      <div class="divider"></div>'
                '      <button class="btn big" onclick="sendAction(''correctImages'')">Correct Images&hellip;</button>'
                '    </div>'
                '  </div>'
                ''
                '  <!-- ============ FLATFIELD ============ -->'
                '  <div class="page" id="page-flatfield">'
                '    <p class="instructions">'
                '      Select a flat-field reference image (an image of a blank/empty field) used to correct'
                '      uneven illumination. This step is optional but recommended, and is normally applied'
                '      before grid and objective correction.'
                '    </p>'
                '    <div class="card">'
                '      <h3>Flatfield Image</h3>'
                '      <div class="filerow">'
                '        <span class="filename empty" id="ffName">none</span>'
                '        <button class="btn secondary" onclick="sendAction(''chooseFlatfield'')">Choose&hellip;</button>'
                '      </div>'
                '    </div>'
                '  </div>'
                ''
                '  <!-- ============ GRID ============ -->'
                '  <div class="page" id="page-grid">'
                '    <p class="instructions">'
                '      Set up the reference grid used to correct TEM-grid-shadow distortion. Choose a reference'
                '      image below, set the plane range, then click Quick Setup to detect and refine the grid'
                '      automatically. Once a plane image opens, step-by-step instructions appear alongside it.'
                '    </p>'
                ''
                '    <div class="card">'
                '      <h3>Reference Image</h3>'
                '      <div class="filerow">'
                '        <span class="filename empty" id="gridRefName">none</span>'
                '        <button class="btn secondary" onclick="sendAction(''chooseGridRef'')">Change&hellip;</button>'
                '      </div>'
                '    </div>'
                ''
                '    <div class="card">'
                '      <h3>Grid Size &amp; Planes</h3>'
                '      <div class="field-grid">'
                '        <label>Grid size (X &times; Y)</label>'
                '        <div>'
                '          <input type="number" id="gridSizeX" min="1" max="50" step="1" onchange="sendAction(''setGridSizeX'', Number(this.value))"> &times;'
                '          <input type="number" id="gridSizeY" min="1" max="50" step="1" onchange="sendAction(''setGridSizeY'', Number(this.value))">'
                '        </div>'
                '        <label>Number of planes</label>'
                '        <input type="number" id="gridSizeZ" min="2" max="100" step="1" onchange="sendAction(''setGridSizeZ'', Number(this.value))">'
                '        <label>Start slide<span class="hint">first grid plane</span></label>'
                '        <input type="number" id="gridPlaneStart" min="1" max="799" step="1" onchange="sendAction(''setGridPlaneStart'', Number(this.value))">'
                '        <label>Averaging<span class="hint">slides averaged per plane</span></label>'
                '        <input type="number" id="gridPlaneAveraging" min="1" max="100" step="1" onchange="sendAction(''setGridPlaneAveraging'', Number(this.value))">'
                '        <label>Slides between planes</label>'
                '        <input type="number" id="gridPlaneInterval" min="10" max="100" step="1" onchange="sendAction(''setGridPlaneInterval'', Number(this.value))">'
                '        <label>End slide<span class="hint">editing this adjusts "slides between planes"</span></label>'
                '        <input type="number" id="gridPlaneEnd" min="1" step="1" onchange="sendAction(''setGridPlaneEnd'', Number(this.value))">'
                '      </div>'
                '    </div>'
                ''
                '    <div class="card">'
                '      <h3>Options</h3>'
                '      <div class="checkbox-row">'
                '        <input type="checkbox" id="verboseOutput" onchange="sendAction(''setVerboseOutput'', this.checked)">'
                '        <label for="verboseOutput">Verbose Output</label>'
                '      </div>'
                '      <div class="checkbox-row">'
                '        <input type="checkbox" id="optimizeGrid" onchange="sendAction(''setOptimizeGrid'', this.checked)">'
                '        <label for="optimizeGrid">Optimize Grid Crossings (fit + smooth)</label>'
                '      </div>'
                '      <div class="checkbox-row">'
                '        <input type="checkbox" id="showFittingFigure" onchange="sendAction(''setShowFittingFigure'', this.checked)">'
                '        <label for="showFittingFigure">Show Fitting Figure</label>'
                '      </div>'
                '      <div class="divider"></div>'
                '      <div class="field-grid">'
                '        <label>Transformation method</label>'
                '        <select id="transformationMethod" onchange="sendAction(''setTransformationMethod'', this.value)">'
                '          <option value="1">affine</option>'
                '          <option value="2">projective</option>'
                '          <option value="3">polynomial (order 3)</option>'
                '          <option value="4">polynomial (order 4)</option>'
                '          <option value="5">piecewise-affine</option>'
                '          <option value="6">piecewise-projective</option>'
                '          <option value="7">piecewise-polynomial order 2</option>'
                '        </select>'
                '        <label>Output shift (X, Y)</label>'
                '        <div>'
                '          <input type="number" id="outputShiftX" min="-1000" max="1000" step="1" onchange="sendAction(''setOutputShiftX'', Number(this.value))">'
                '          <input type="number" id="outputShiftY" min="-1000" max="1000" step="1" onchange="sendAction(''setOutputShiftY'', Number(this.value))">'
                '        </div>'
                '      </div>'
                '    </div>'
                ''
                '    <div style="display:flex; gap:8px;">'
                '      <button class="btn big" id="quickSetupBtn" onclick="sendAction(''quickSetup'')">Quick Setup</button>'
                '      <button class="btn secondary" onclick="sendAction(''resetSettings'')">Reset</button>'
                '    </div>'
                '    <div style="margin-top:8px;">'
                '      <button class="btn big secondary" id="viewGridEditorBtn" onclick="sendAction(''viewGridEditor'')">View / Edit Grid&hellip;</button>'
                '    </div>'
                '  </div>'
                ''
                '  <!-- ============ OBJECTIVE ============ -->'
                '  <div class="page" id="page-objective">'
                '    <p class="instructions">'
                '      Objective/lens distortion is corrected using a calibration file produced by an external'
                '      tool. Select that .mat file below, then choose the fitting style to use.'
                '    </p>'
                '    <div class="card">'
                '      <h3>Calibration File</h3>'
                '      <div class="filerow">'
                '        <span class="filename empty" id="objName">none</span>'
                '        <button class="btn secondary" onclick="sendAction(''chooseObjective'')">Choose&hellip;</button>'
                '      </div>'
                '    </div>'
                '    <div class="card">'
                '      <h3>Fitting Style</h3>'
                '      <div class="field-grid">'
                '        <label>Style</label>'
                '        <select id="style" onchange="sendAction(''setStyle'', this.value)">'
                '          <option value="STV 0, All Points">STV 0, All Points</option>'
                '          <option value="STV 0, 4 points">STV 0, 4 points</option>'
                '          <option value="Force Hexagon">Force Hexagon</option>'
                '        </select>'
                '      </div>'
                '    </div>'
                '  </div>'
                ''
                '</div>'
                ''
                '<script type="text/javascript">'
                '  var latestModel = null;'
                '  var lastNavigateToken = -1;'
                ''
                '  var pageTitles = {'
                '    home: "Image Distortion Correction",'
                '    flatfield: "Flatfield Setup",'
                '    grid: "Grid Distortion Setup",'
                '    objective: "Objective Correction Setup"'
                '  };'
                ''
                '  function showPage(name) {'
                '    var pages = document.querySelectorAll(".page");'
                '    for (var i = 0; i < pages.length; i++) { pages[i].classList.remove("active"); }'
                '    document.getElementById("page-" + name).classList.add("active");'
                '    document.getElementById("pageTitle").innerText = pageTitles[name];'
                '    document.getElementById("backBtn").style.display = (name === "home") ? "none" : "inline-block";'
                '  }'
                ''
                '  function setFileDisplay(el, name, fullPath) {'
                '    if (name) {'
                '      el.innerText = name;'
                '      el.title = fullPath || name;'
                '      el.classList.remove("empty");'
                '    } else {'
                '      el.innerText = "none";'
                '      el.title = "";'
                '      el.classList.add("empty");'
                '    }'
                '  }'
                ''
                '  function setIfNotFocused(el, value) {'
                '    if (document.activeElement !== el) { el.value = value; }'
                '  }'
                ''
                '  function render(model) {'
                '    if (!model) { return; }'
                '    latestModel = model;'
                ''
                '    // A one-time forced navigation request from MATLAB (e.g. the grid'
                '    // editor''s Finish button should land on Home, not wherever this page'
                '    // happened to be showing before) -- guarded by a token so it only'
                '    // fires once per request, not on every subsequent unrelated refresh.'
                '    if (model.navigateToken !== undefined && model.navigateToken !== lastNavigateToken) {'
                '      lastNavigateToken = model.navigateToken;'
                '      if (model.navigateTo) { showPage(model.navigateTo); }'
                '    }'
                ''
                '    // Home'
                '    document.getElementById("ffStatus").innerText = model.ffStatus;'
                '    document.getElementById("ffStatus").classList.toggle("configured", model.ffName !== "");'
                '    document.getElementById("gridStatus").innerText = model.gridStatus;'
                '    document.getElementById("gridStatus").classList.toggle("configured", model.gridStatus.indexOf("Configured") === 0);'
                '    document.getElementById("objStatus").innerText = model.objStatus;'
                '    document.getElementById("objStatus").classList.toggle("configured", model.objName !== "");'
                '    setFileDisplay(document.getElementById("currentSettingsName"), model.currentSettingsName, model.currentSettingsFullPath);'
                ''
                '    document.getElementById("applyFF").checked = !!model.applyFF;'
                '    document.getElementById("applyFF").disabled = !model.applyFFEnabled;'
                '    document.getElementById("applyFFRow").classList.toggle("disabled", !model.applyFFEnabled);'
                '    document.getElementById("applyGC").checked = !!model.applyGC;'
                '    document.getElementById("applyGC").disabled = !model.applyGCEnabled;'
                '    document.getElementById("applyGCRow").classList.toggle("disabled", !model.applyGCEnabled);'
                '    document.getElementById("applyDC").checked = !!model.applyDC;'
                '    document.getElementById("applyDC").disabled = !model.applyDCEnabled;'
                '    document.getElementById("applyDCRow").classList.toggle("disabled", !model.applyDCEnabled);'
                ''
                '    // Flatfield'
                '    setFileDisplay(document.getElementById("ffName"), model.ffName, model.ffFullPath);'
                ''
                '    // Grid'
                '    setFileDisplay(document.getElementById("gridRefName"), model.gridRefName, model.gridRefFullPath);'
                '    setIfNotFocused(document.getElementById("gridSizeX"), model.gridSizeX);'
                '    setIfNotFocused(document.getElementById("gridSizeY"), model.gridSizeY);'
                '    setIfNotFocused(document.getElementById("gridSizeZ"), model.gridSizeZ);'
                '    setIfNotFocused(document.getElementById("gridPlaneStart"), model.gridPlaneStart);'
                '    setIfNotFocused(document.getElementById("gridPlaneAveraging"), model.gridPlaneAveraging);'
                '    setIfNotFocused(document.getElementById("gridPlaneInterval"), model.gridPlaneInterval);'
                '    setIfNotFocused(document.getElementById("gridPlaneEnd"), model.gridPlaneEnd);'
                ''
                '    document.getElementById("verboseOutput").checked = !!model.verboseOutput;'
                '    document.getElementById("optimizeGrid").checked = !!model.optimizeGrid;'
                '    document.getElementById("showFittingFigure").checked = !!model.showFittingFigure;'
                '    document.getElementById("transformationMethod").value = model.transformationMethod;'
                '    setIfNotFocused(document.getElementById("outputShiftX"), model.outputShiftX);'
                '    setIfNotFocused(document.getElementById("outputShiftY"), model.outputShiftY);'
                ''
                '    var gridInputs = ["gridSizeX", "gridSizeY", "gridSizeZ", "gridPlaneStart", "gridPlaneAveraging", "gridPlaneInterval", "gridPlaneEnd"];'
                '    for (var i = 0; i < gridInputs.length; i++) {'
                '      document.getElementById(gridInputs[i]).disabled = !model.gridFieldsEnabled;'
                '    }'
                '    document.getElementById("quickSetupBtn").disabled = !model.quickSetupEnabled;'
                '    document.getElementById("viewGridEditorBtn").disabled = !model.viewEditorEnabled;'
                '    // Once a grid exists to view/edit, that becomes the highlighted'
                '    // default action instead of Quick Setup (which is hard-disabled by'
                '    // then anyway, until Reset) -- swap which one reads as "primary".'
                '    document.getElementById("quickSetupBtn").classList.toggle("secondary", model.viewEditorEnabled);'
                '    document.getElementById("viewGridEditorBtn").classList.toggle("secondary", !model.viewEditorEnabled);'
                ''
                '    // Objective'
                '    setFileDisplay(document.getElementById("objName"), model.objName, model.objFullPath);'
                '    document.getElementById("style").value = model.style;'
                '  }'
                ''
                '  function setup(htmlComponent) {'
                '    window.mainUI = htmlComponent;'
                '    htmlComponent.addEventListener("DataChanged", function(event) {'
                '      render(event.Data);'
                '    });'
                '    render(htmlComponent.Data);'
                '  }'
                ''
                '  function sendAction(action, value) {'
                '    var payload = { action: action };'
                '    if (value !== undefined) { payload.value = value; }'
                '    window.mainUI.Data = payload;'
                '  }'
                '</script>'
                ''
                '</body>'
                '</html>'
                ''
            };
            html = strjoin(lines, newline);
        end

        function html = BuildGridSidebarHTML(~)
            % GridSidebarUI's HTML/CSS/JS -- replaces the old annotation-
            % based legend/instructions and uicontrol-based nav/action
            % buttons, styled to match MainUI's dashboard cards.
            lines = {
                '<!DOCTYPE html>'
                '<html>'
                '<head>'
                '<meta charset="UTF-8">'
                '<style>'
                '  :root {'
                '    --bg: #f3f4f6;'
                '    --card-bg: #ffffff;'
                '    --border: #dde1e6;'
                '    --text: #1f2328;'
                '    --text-secondary: #616873;'
                '    --accent: #0072bd;'
                '    --accent-hover: #005a94;'
                '    --ok: #1a7f37;'
                '    --muted: #8a919b;'
                '  }'
                '  * { box-sizing: border-box; }'
                '  html, body {'
                '    margin: 0; padding: 0; height: 100%;'
                '    background: var(--bg);'
                '    color: var(--text);'
                '    font-family: -apple-system, "Segoe UI", Helvetica, Arial, sans-serif;'
                '    font-size: 12.5px;'
                '    overflow-y: auto;'
                '  }'
                '  .content { padding: 10px; }'
                '  .back-btn {'
                '    border: 1px solid var(--accent); background: #fff; cursor: pointer;'
                '    color: var(--accent); font-size: 13px; font-weight: 700;'
                '    padding: 6px 12px; border-radius: 6px;'
                '    display: block; width: 100%; text-align: center;'
                '    margin-bottom: 10px;'
                '  }'
                '  .back-btn:hover { background: #eef6fc; color: var(--accent-hover); border-color: var(--accent-hover); }'
                '  .title { font-size: 14px; font-weight: 700; margin: 0 0 10px; }'
                '  .plane-label {'
                '    color: var(--text); font-size: 20px; font-weight: 700;'
                '    text-align: center; margin: 0 0 6px;'
                '  }'
                '  .card {'
                '    background: var(--card-bg);'
                '    border: 1px solid var(--border);'
                '    border-radius: 10px;'
                '    padding: 10px 12px;'
                '    margin-bottom: 10px;'
                '  }'
                '  .card h3 {'
                '    margin: 0 0 6px;'
                '    font-size: 12px;'
                '    font-weight: 700;'
                '  }'
                '  .instructions-text { color: var(--text-secondary); line-height: 1.4; margin: 0; }'
                '  .origin-info { color: var(--text); font-weight: 600; margin: 6px 0 0; font-size: 12px; }'
                '  .legend-row { display: flex; align-items: center; gap: 8px; padding: 3px 0; }'
                '  .legend-dot { width: 11px; height: 11px; border-radius: 50%; flex-shrink: 0; border: 1px solid rgba(0,0,0,0.15); }'
                '  .legend-label { color: var(--text-secondary); font-size: 11.5px; }'
                '  .nav-row { display: flex; gap: 6px; margin-bottom: 10px; }'
                '  .btn {'
                '    border: 1px solid var(--accent);'
                '    background: var(--accent);'
                '    color: #fff;'
                '    border-radius: 6px;'
                '    padding: 7px 10px;'
                '    font-size: 12px;'
                '    font-weight: 600;'
                '    cursor: pointer;'
                '    width: 100%;'
                '  }'
                '  .btn:hover { background: var(--accent-hover); border-color: var(--accent-hover); }'
                '  .btn.secondary { background: #fff; color: var(--accent); }'
                '  .btn.secondary:hover { background: #eef6fc; }'
                '  .btn.nav { flex: 1; padding: 6px 4px; font-size: 11px; }'
                '  .btn:disabled { background: #e7e9ec; border-color: #e7e9ec; color: var(--muted); cursor: not-allowed; }'
                '  .btn.finish { background: var(--ok); border-color: var(--ok); }'
                '  .btn.finish:hover { background: #14602c; border-color: #14602c; }'
                '  .action-btn { margin-bottom: 6px; }'
                '  .divider { height: 1px; background: var(--border); margin: 10px 0; }'
                '  .section-label {'
                '    color: var(--muted); font-size: 10.5px; font-weight: 700;'
                '    text-transform: uppercase; letter-spacing: 0.03em;'
                '    margin: 0 0 6px;'
                '  }'
                '  .method-row { margin-bottom: 8px; }'
                '  .method-row label {'
                '    display: block; color: var(--muted); font-size: 11px; margin-bottom: 3px;'
                '  }'
                '  .method-row select {'
                '    width: 100%; box-sizing: border-box; padding: 4px 6px; font-size: 11.5px;'
                '    background: var(--card-bg); color: var(--text);'
                '    border: 1px solid var(--border); border-radius: 4px;'
                '  }'
                '  [hidden] { display: none !important; }'
                '  .invisible-space { visibility: hidden; pointer-events: none; }'
                '</style>'
                '</head>'
                '<body>'
                ''
                '<div class="content">'
                '  <button class="back-btn" onclick="sendAction(''backToDashboard'')">&larr; Back to Grid Setup</button>'
                '  <div class="title">Grid Editor</div>'
                ''
                '  <div class="card" id="legendCard">'
                '    <h3>Point Colors</h3>'
                '    <div class="legend-row"><span class="legend-dot" style="background:rgb(0,114,189)"></span><span class="legend-label">Measured (converged)</span></div>'
                '    <div class="legend-row"><span class="legend-dot" style="background:rgb(255,140,191)"></span><span class="legend-label">Outlier (surface-corrected)</span></div>'
                '    <div class="legend-row"><span class="legend-dot" style="background:rgb(255,51,191)"></span><span class="legend-label">Unrefined / no fit</span></div>'
                '    <div class="legend-row"><span class="legend-dot" style="background:rgb(51,204,255)"></span><span class="legend-label">Filled from other planes (Z)</span></div>'
                '  </div>'
                ''
                '  <div class="card">'
                '    <h3>Instructions</h3>'
                '    <p class="instructions-text" id="instructionsText"></p>'
                '    <p class="origin-info" id="originInfo" hidden></p>'
                '  </div>'
                ''
                '  <button class="btn secondary action-btn" id="btnAdjustOrigin" onclick="sendAction(''adjustOrigin'')">Adjust Grid Origin</button>'
                ''
                '  <div class="plane-label" id="planeLabel">Plane 1 / 1</div>'
                '  <div id="navRow" class="nav-row">'
                '    <button class="btn secondary nav" id="navFirst" onclick="sendAction(''first'')">|&lt; First</button>'
                '    <button class="btn secondary nav" id="navPrev" onclick="sendAction(''prev'')">&lt; Prev</button>'
                '    <button class="btn secondary nav" id="navNext" onclick="sendAction(''next'')">Next &gt;</button>'
                '    <button class="btn secondary nav" id="navLast" onclick="sendAction(''last'')">Last &gt;|</button>'
                '  </div>'
                ''
                '  <p class="section-label" id="adjustLabel">Review &amp; adjust this plane (optional)</p>'
                '  <button class="btn secondary action-btn" id="btnOptimizePlane" onclick="sendAction(''optimizePlane'')">Optimize This Plane</button>'
                '  <div id="methodRow" class="method-row">'
                '    <label for="gridTransformationMethod">Correction model</label>'
                '    <select id="gridTransformationMethod" onchange="sendAction(''setTransformationMethod'', this.value)">'
                '      <option value="1">1: affine</option>'
                '      <option value="2">2: projective</option>'
                '      <option value="3">3: polynomial (order 3)</option>'
                '      <option value="4">4: polynomial (order 4)</option>'
                '      <option value="5">5: piecewise-affine</option>'
                '      <option value="6">6: piecewise-projective</option>'
                '      <option value="7">7: piecewise-polynomial order 2</option>'
                '    </select>'
                '  </div>'
                '  <button class="btn secondary action-btn" id="btnCorrectionTest" onclick="sendAction(''correctionTest'')">Correction test on current model</button>'
                '  <button class="btn secondary action-btn" id="btnCompareAllModels" onclick="sendAction(''compareAllModels'')">Compare All Models</button>'
                ''
                '  <div class="divider" id="populateDivider"></div>'
                ''
                '  <button class="btn action-btn" id="btnPopulateRest" onclick="sendAction(''populateRest'')">Populate the Rest&hellip;</button>'
                ''
                '  <div id="readyExtrasGroup" hidden>'
                '    <p class="section-label">Optional refinement (once every plane is done)</p>'
                '    <button class="btn secondary action-btn" id="btnRefineAllPlanes" onclick="sendAction(''refineAllPlanes'')">Refine All Planes</button>'
                '    <button class="btn secondary action-btn" id="btnVerifyOverall" onclick="sendAction(''verifyOverallCorrection'')">Verify Overall Correction</button>'
                '  </div>'
                ''
                '  <button class="btn finish action-btn" id="btnFinish" onclick="sendAction(''finish'')" hidden>&#10003; Finish</button>'
                '</div>'
                ''
                '<script type="text/javascript">'
                '  function render(model) {'
                '    if (!model) { return; }'
                ''
                '    document.getElementById("planeLabel").innerText = "Plane " + model.planeCurrent + " / " + model.planeTotal;'
                '    document.getElementById("instructionsText").innerText = model.instructionsText;'
                ''
                '    var originMode = (model.sidebarMode === "originConfirm");'
                '    document.getElementById("originInfo").hidden = !originMode;'
                '    if (originMode) {'
                '      document.getElementById("originInfo").innerText = model.originConfirmInfo;'
                '    }'
                ''
                '    document.getElementById("legendCard").hidden = originMode;'
                '    document.getElementById("navRow").hidden = originMode;'
                '    document.getElementById("adjustLabel").hidden = originMode;'
                '    document.getElementById("methodRow").hidden = originMode;'
                '    document.getElementById("gridTransformationMethod").value = model.transformationMethod;'
                '    document.getElementById("btnCorrectionTest").hidden = originMode;'
                '    document.getElementById("btnOptimizePlane").hidden = originMode;'
                '    document.getElementById("populateDivider").hidden = originMode;'
                '    document.getElementById("btnPopulateRest").hidden = originMode;'
                '    document.getElementById("readyExtrasGroup").hidden = originMode || !model.allPlanesReady;'
                '    document.getElementById("btnFinish").hidden = originMode || !model.allPlanesReady;'
                ''
                '    document.getElementById("btnAdjustOrigin").classList.toggle("invisible-space", Number(model.planeCurrent) !== 1);'
                '    document.getElementById("btnAdjustOrigin").innerText = originMode ? "Confirm Origin" : "Adjust Grid Origin";'
                ''
                '    var nav = model.nav || {};'
                '    document.getElementById("navFirst").disabled = !nav.first;'
                '    document.getElementById("navPrev").disabled = !nav.prev;'
                '    document.getElementById("navNext").disabled = !nav.next;'
                '    document.getElementById("navLast").disabled = !nav.last;'
                '    document.getElementById("btnCorrectionTest").disabled = !nav.correctionTest;'
                '    document.getElementById("btnCompareAllModels").disabled = !nav.correctionTest;'
                '    document.getElementById("btnOptimizePlane").disabled = !nav.optimizePlane;'
                '    document.getElementById("btnAdjustOrigin").disabled = !nav.adjustOrigin;'
                '    document.getElementById("btnPopulateRest").disabled = !nav.populateRest;'
                '  }'
                ''
                '  function setup(htmlComponent) {'
                '    window.sidebarUI = htmlComponent;'
                '    htmlComponent.addEventListener("DataChanged", function(event) {'
                '      render(event.Data);'
                '    });'
                '    render(htmlComponent.Data);'
                '  }'
                ''
                '  function sendAction(action, value) {'
                '    var payload = { action: action };'
                '    if (value !== undefined) { payload.value = value; }'
                '    window.sidebarUI.Data = payload;'
                '  }'
                '</script>'
                ''
                '</body>'
                '</html>'
                ''
            };
            html = strjoin(lines, newline);
        end
    end

    % Component initialization
    methods (Access = private)

        % Create UIFigure and components
        function createComponents(app)

            % Create ImageCorrectionDialogUIFigure and hide until all components are created
            app.ImageCorrectionDialogUIFigure = uifigure('Visible', 'off');
            app.ImageCorrectionDialogUIFigure.Position = [0 0 480 900];
            app.ImageCorrectionDialogUIFigure.Name = 'Image Correction Dialog';
            app.ImageCorrectionDialogUIFigure.CloseRequestFcn = createCallbackFcn(app, @ImageCorrectionDialogUIFigureCloseRequest, true);
            % AutoResizeChildren would proportionally rescale MainUI's
            % Position on every resize, but MATLAB then refuses to also
            % fire SizeChangedFcn -- turn it off so the explicit handler
            % below can just keep MainUI filling the figure exactly.
            app.ImageCorrectionDialogUIFigure.AutoResizeChildren = 'off';
            app.ImageCorrectionDialogUIFigure.SizeChangedFcn = createCallbackFcn(app, @ImageCorrectionDialogUIFigureSizeChanged, true);

            % V5: the entire dashboard/setup UI is a single HTML/CSS/JS
            % single-page app hosted in one uihtml component filling the
            % figure, instead of the native uicontrols V2-V4 used.
            % MainUIDataChanged dispatches every click/field-change event
            % the page sends back to the same callback functions the old
            % uicontrols used to invoke; BuildViewModel/PushViewModel push
            % the app's current state back to the page after every action.
            app.MainUI = uihtml(app.ImageCorrectionDialogUIFigure);
            app.MainUI.Position = [0 0 480 900];
            app.MainUI.HTMLSource = BuildMainUIHTML(app);
            app.MainUI.DataChangedFcn = createCallbackFcn(app, @MainUIDataChanged, true);

            % V6: the interactive grid-point editor, hidden until
            % EnterGridEditorMode switches this same figure into showing
            % it instead of MainUI. GridAxes replaces the old figure(1)'s
            % image axes (drawpoint/ROIMoved/ROIClicked work identically
            % on a uiaxes); GridSidebarUI replaces the old annotation/
            % uicontrol sidebar with an HTML page matching MainUI's look.
            app.GridAxes = uiaxes(app.ImageCorrectionDialogUIFigure);
            app.GridAxes.Visible = 'off';
            app.GridAxes.Toolbar.Visible = 'off';

            app.GridSidebarUI = uihtml(app.ImageCorrectionDialogUIFigure);
            app.GridSidebarUI.Visible = 'off';
            app.GridSidebarUI.HTMLSource = BuildGridSidebarHTML(app);
            app.GridSidebarUI.DataChangedFcn = createCallbackFcn(app, @GridSidebarDataChanged, true);

            % Show the figure after all components are created
            app.ImageCorrectionDialogUIFigure.Visible = 'on';
        end

        % Keeps MainUI (dashboard mode) or GridAxes+GridSidebarUI (grid-
        % editor mode) filling the whole figure as the user resizes the
        % window -- exactly one of the two layouts is active at a time
        % (see EnterGridEditorMode/ExitGridEditorMode/LayoutGridEditor).
        function ImageCorrectionDialogUIFigureSizeChanged(app, event)
            if app.ui_GridEditorMode
                LayoutGridEditor(app);
            else
                figPos = app.ImageCorrectionDialogUIFigure.Position;
                app.MainUI.Position = [0 0 figPos(3) figPos(4)];
            end
        end
    end

    % App creation and deletion
    methods (Access = public)

        % Construct app
        function app = ImagePostProcessingDlgV08(varargin)

            % Create UIFigure and components
            createComponents(app)

            % Register the app with App Designer
            registerApp(app, app.ImageCorrectionDialogUIFigure)

            % Execute the startup function
            runStartupFcn(app, @(app)startupFcn(app, varargin{:}))

            if nargout == 0
                clear app
            end
        end

        function img = GridGetPlaneImage(app, plane)
            % Read-only accessor for a plane's reference image buffer --
            % grid_PlaneImgBuf is private, but external diagnostic/
            % visualization scripts (e.g. plotting GridLastCompareResults
            % over the real image) need pixel data to overlay onto.
            img = app.grid_PlaneImgBuf(:,:,plane);
        end

        function [posOut, statusOut, rmseOut] = GridTestRunBaselineOnImage(app, testImage, seedXY, dx1, dy1)
            % TEST HARNESS ONLY -- runs the unmodified baseline local fit
            % (GridPositionOptimize/GridProfile/GridFitting) against a
            % caller-supplied image and caller-supplied seed positions.
            %
            % Exists so an external script can score the baseline against
            % SYNTHETIC ground truth, which is otherwise impossible: real
            % data has no independently-known true crossing position (the
            % reason GridCompareFittingMethods has to fall back on the
            % surface-residual consistency proxy), and GridPositionOptimize
            % is private and reads app.ref_Image rather than taking an
            % image argument. Same read-only spirit as GridGetPlaneImage
            % above: app.ref_Image is saved and restored, and nothing here
            % touches grid_Position/grid_Info/grid_LatticeModel.
            %
            %   seedXY  : N x 2 seed positions, [X Y] (same convention as
            %             grid_Position), typically lattice predictions.
            %   dx1,dy1 : spacing vector along lattice axis 1, used only to
            %             orient the local search patch -- exactly what
            %             GridLatticeLocalSpacing(...,1) returns.
            nPts = size(seedXY,1);
            posOut = nan(nPts,2);
            statusOut = zeros(nPts,1);
            rmseOut = nan(nPts,1);

            savedImage = app.ref_Image;
            app.ref_Image = testImage;
            try
                for k = 1:nPts
                    [newPos, fitStatus, fitQuality] = GridPositionOptimize(app, seedXY(k,:), dx1, dy1);
                    statusOut(k) = fitStatus;
                    if fitStatus == 1
                        posOut(k,:) = newPos;
                        % GridPositionOptimize's fitQuality is a struct
                        % carrying the two marginalized 1D fits' residuals
                        % separately (rmseX/rmseY); reported here as their
                        % mean, matching how the comparison routine treats
                        % "the" fit residual for a point.
                        rmseOut(k) = mean([fitQuality.rmseX fitQuality.rmseY]);
                    else
                        posOut(k,:) = seedXY(k,:);
                    end
                end
            catch ME
                app.ref_Image = savedImage;
                rethrow(ME);
            end
            app.ref_Image = savedImage;
        end

        % Code that executes before app deletion
        function delete(app)

            % Close any plain figure windows (grid display, fitting-debug
            % plots, correction-test views) this app may have created, so
            % none are left orphaned however the app gets closed.
            GridCloseFigures(app);

            % Delete UIFigure when app is deleted
            delete(app.ImageCorrectionDialogUIFigure)
        end
    end
end