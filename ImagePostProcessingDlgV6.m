classdef ImagePostProcessingDlgV6 < matlab.apps.AppBase

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
        debug=1;                                %debug mode
        debugPlot=false;                        %plot fit results in debug mode; synced from
                                                 %ShowFittingFigureCheckBox, off by default since it
                                                 %redraws on every single-point fit during batch population

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
                app.grid_PlaneImgBuf(:,:,index)=tempImage;
                if dlg.CancelRequested
                    break
                end
            end
            close(dlg);

            app.ImgBufReady=true;
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
                
                iL=floor((app.grid_SizeX-1)/2);
                jL=floor((app.grid_SizeY-1)/2);

                correctedImage=zeros(mini_ImageSize*jL, mini_ImageSize*iL);
                
                for j=1:jL
                    for i=1:iL
                        i_current=1+(i-1)*2;
                        j_current=1+(j-1)*2;
                        for n=1:3
                            for m=1:3
                                index_mini=m+(n-1)*3;
                                index_world=i_current+m-1+(j_current+n-2)*app.grid_SizeX;
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

                        correctedminiImage=imwarp(app.ref_Image, tform, 'interp', 'cubic', 'Outputview', RA_mini); %nearest, linear or cubic
                        correctedImage((xOutput(1)+1):xOutput(2), (yOutput(1)+1):yOutput(2))=correctedminiImage;
                    end
                end
            end

            figHandle=figure(2);
            set(figHandle, 'NumberTitle', 'off', 'Name', sprintf('Grid Correction Test on Plane #%d', app.grid_PlaneCurrent));
            
            subplot(1,2,1);
            imshow(app.ref_Image, [0 3]);
            title('Before Correction');
            subplot(1,2,2);
            imshow(correctedImage, [0 3]);
            title('After Correction');

            %check intensity change
%            intensity_original=sum(app.ref_Image, "all");
%            intensity_corrected=sum(correctedImage, "all");
%            intensity_original
%            intensity_corrected
           
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
        
            [offsetX,fitOKX,rmseX] = ...
                GridFitting(app,profileX,1);
        
            [offsetY,fitOKY,rmseY] = ...
                GridFitting(app,profileY,2);
        
            fitQuality.rmseX = rmseX;
            fitQuality.rmseY = rmseY;
        
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
        
            if app.debug && app.debugPlot
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

        function [offset,fitOK,fitRMSE] = ...
                GridFitting(app,lprofile,num)
        
            offset = 0;
            fitOK = false;
            fitRMSE = inf;
        
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
        
            if app.debug && app.debugPlot
                figure(2);
                subplot(1,3,num+1);
                hold on;
                plot(xPos,model(fitParameters,xPos));
                hold off;
            end
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
            sidebarWidthPx = 260;
            marginPx = 10;
            gapPx = 8;
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
                    'looks shifted or rotated, use "Adjust Grid Origin" to realign it, or "Optimize ' ...
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

            topMargin=grid_Position_Current(1,2);
            bottomMargin=sizeInput(2)-topMargin;
            
            leftMargin=grid_Position_Current(1,1);
            rightMargin=sizeInput(1)-leftMargin;

            yWorldLimits = [-topMargin+app.image_OutputShiftY bottomMargin+app.image_OutputShiftY];
            xWorldLimits = [-leftMargin-app.image_OutputShiftX rightMargin-app.image_OutputShiftX];
            RA = imref2d(flip(sizeOutput),xWorldLimits,yWorldLimits);
%                RA = imref2d(sizeOutput, );

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
            elseif nGood < 15
                surfaceOrder = 'poly11';
            elseif nGood < 30
                surfaceOrder = 'poly22';
            else
                surfaceOrder = 'poly23';
            end

            warnState = warning('off','curvefit:fit:iterationLimitReached'); % benign on very clean data
            sfX = fit([gx(goodMask) gy(goodMask)], rawXY(goodMask,1), surfaceOrder, 'Robust','Bisquare');
            sfY = fit([gx(goodMask) gy(goodMask)], rawXY(goodMask,2), surfaceOrder, 'Robust','Bisquare');
            warning(warnState);

            predX = sfX(gx,gy);
            predY = sfY(gx,gy);

            residX = rawXY(goodMask,1) - predX(goodMask);
            residY = rawXY(goodMask,2) - predY(goodMask);
            resid = hypot(residX, residY);
            outlierThresh = max(3, 3*1.4826*mad(resid,1));

            for index=1:nTotal
                app.grid_Position(index,:,plane) = [predX(index) predY(index)];
                if goodMask(index)
                    r = hypot(rawXY(index,1)-predX(index), rawXY(index,2)-predY(index));
                    app.grid_Info{index,plane}.surfaceResidual = r;
                    if r > outlierThresh
                        app.grid_Info{index,plane}.status = 2; %outlier
                    else
                        app.grid_Info{index,plane}.status = 1; %good
                    end
                else
                    app.grid_Info{index,plane}.surfaceResidual = NaN;
                    app.grid_Info{index,plane}.status = 1; %filled in from the smooth trend
                    app.grid_Info{index,plane}.source = 'surface';
                end
            end

            app.grid_SurfaceModel{plane} = struct('sfX',sfX,'sfY',sfY, ...
                'order',surfaceOrder,'nPointsUsed',nGood,'qualityFraction',nGood/nTotal);

            rmseX = sqrt(mean(residX.^2));
            rmseY = sqrt(mean(residY.^2));
            fitStatus = 1;
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

        function GridCheckPlaneContinuity(app, plane)
            % Non-blocking sanity check (NOT a propagation dependency):
            % warn if this plane's detected lattice differs sharply from
            % the previous plane's, since the physical grid should drift
            % only gradually across an eV/focus series.
            if plane < 2 || numel(app.grid_LatticeModel) < plane ...
                    || isempty(app.grid_LatticeModel{plane-1}) || isempty(app.grid_LatticeModel{plane})
                return;
            end
            prevModel = app.grid_LatticeModel{plane-1};
            curModel = app.grid_LatticeModel{plane};

            spacingChange1 = abs(curModel.d1-prevModel.d1)/prevModel.d1;
            spacingChange2 = abs(curModel.d2-prevModel.d2)/prevModel.d2;
            angleChange1 = abs(curModel.theta1-prevModel.theta1);
            angleChange2 = abs(curModel.theta2-prevModel.theta2);

            if spacingChange1>0.05 || spacingChange2>0.05 || angleChange1>2 || angleChange2>2
                GridLog(app, ['Plane %d: detected lattice differs notably from plane %d ' ...
                     '(spacing change %.1f%%/%.1f%%, angle change %.1f/%.1fdeg). ' ...
                     'Consider visually re-checking this plane.'], ...
                    plane, plane-1, spacingChange1*100, spacingChange2*100, angleChange1, angleChange2);
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
                error('GridCorrection:NoLatticeModel', ...
                    'No lattice model available for plane %d; run Setup Grid Points / Populate first.', plane);
            end

            latticeModel.predictedPos = predictedPos;
            latticeModel.localSpacing = localSpacing;
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

            planeConfidence = ones(nZ,1);
            planeQuality = ones(nZ,1);
            for z = 1:nZ
                if numel(app.grid_LatticeModel) >= z && ~isempty(app.grid_LatticeModel{z}) ...
                        && isfield(app.grid_LatticeModel{z},'confidence')
                    planeConfidence(z) = app.grid_LatticeModel{z}.confidence;
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
                        planeConfidence(z) >= 1 && planeQuality(z) >= 0.5;
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

            planeConfidence = ones(plane-1,1);
            planeQuality = ones(plane-1,1);
            for z = 1:plane-1
                if numel(app.grid_LatticeModel) >= z && ~isempty(app.grid_LatticeModel{z}) ...
                        && isfield(app.grid_LatticeModel{z},'confidence')
                    planeConfidence(z) = app.grid_LatticeModel{z}.confidence;
                end
                if numel(app.grid_SurfaceModel) >= z && ~isempty(app.grid_SurfaceModel{z}) ...
                        && isfield(app.grid_SurfaceModel{z},'qualityFraction')
                    planeQuality(z) = app.grid_SurfaceModel{z}.qualityFraction;
                end
            end

            predictedPos = zeros(nTotal,2);
            haveHistory = false(nTotal,1);

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
                                planeConfidence(z) >= 1 && planeQuality(z) >= 0.5
                            zHist(end+1) = z; %#ok<AGROW>
                            xHist(end+1) = app.grid_Position(index,1,z); %#ok<AGROW>
                            yHist(end+1) = app.grid_Position(index,2,z); %#ok<AGROW>
                        end
                    end

                    if numel(zHist) >= 3
                        warnState = warning('off','curvefit:fit:iterationLimitReached');
                        sfXz = fit(zHist(:), xHist(:), 'poly1', 'Robust','Bisquare');
                        sfYz = fit(zHist(:), yHist(:), 'poly1', 'Robust','Bisquare');
                        warning(warnState);
                        predictedPos(index,:) = [sfXz(plane) sfYz(plane)];
                        haveHistory(index) = true;
                    elseif numel(zHist) >= 1
                        % Not enough points for a trend yet -- carry the
                        % last trusted value forward as the best available
                        % guess (still better than a from-scratch lattice
                        % guess for a point with known real distortion).
                        predictedPos(index,:) = [xHist(end) yHist(end)];
                        haveHistory(index) = true;
                    end
                end
            end

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
        end

        % Button pushed function: SaveSettingsButton
        function SaveSettingsButtonPushed(app, event)
            [filename,filepath]=uiputfile('*.mat','Save Current settings');
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

        end

        % Button pushed function: LoadSettingsButton
        function LoadSettingsButtonPushed(app, event)
          if app.debug==0
                [filename,filepath]=uigetfile('*.mat','Load old settings');
                if filename == 0
                    return;
                end
          else
                filepath= 'Distortion Grid\';
                filename= 'GC_20221219v2.mat';
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
          catch
                 app.filename_CurrentSettings='Invalid file!';
          end
            SetGridPlaneParameter(app);

            GridSettingStatusChange(app, app.grid_SettingStatus);
            app.grid_PlaneCurrent=1;
            GridUpdatePlaneLabel(app);

            
        end

        % Close request function: ImageCorrectionDialogUIFigure
        function ImageCorrectionDialogUIFigureCloseRequest(app, event)
            
            if(app.grid_SettingStatus)
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
            [ff_filename,ff_filepath]=uigetfile('*.tiff;*.tif','Choose a flatfield image');
            if ff_filename == 0
                return;
            end
            
            app.filename_Flatfield=[ff_filepath ff_filename];

        end

        % Button pushed function: ChangeRefImageButton
        function ChangeRefImageButtonPushed(app, event)
            if app.debug==0
                [filename,filepath]=uigetfile('*.tiff;*.tif','Choose a reference image');
                if filename == 0
                    return;
                end
            else
                filename= 'GC 20260212_1_30kcps.tiff';
                filepath= 'C:\Users\micha\OneDrive - OIST\Experiments\2026 Twisted WSe2\GC\';
            end
            app.filename_GridRef=[filepath filename];
            GridSettingStatusChange(app, app.grid_SettingStatus)
            

        end

        % Button pushed function: ChangeObjDistortionButton
        function ChangeObjDistortionButtonPushed(app, event)
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
                FFImage=imread(app.filename_Flatfield, 1);
                FFImage=single(FFImage);
                %select center region and calculate average intensity there
                FFImageSize=size(FFImage);
                CropFFImage=FFImage(FFImageSize(1)*0.25:FFImageSize(1)*0.75, FFImageSize(1)*0.25:FFImageSize(2)*0.75);
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
            end
            
            if(app.ui_ApplyDC==true)
                load(app.filename_GeometricDistortion,"-mat",'lens_distortion_ref_K',...
                    'd');
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
                
                if(app.ui_ApplyGC==true)
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

                        transformationMethod=str2double(app.ui_TransformationMethod);
                        switch(transformationMethod)
                            case 1
                                tform = fitgeotrans(grid_Position_Spline(:,:,iZ),worldPoints,"affine");
                            case 2
                                tform = fitgeotrans(grid_Position_Spline(:,:,iZ),worldPoints,"projective");
                            case 3
                                tform = fitgeotrans(grid_Position_Spline(:,:,iZ),worldPoints,"polynomial", 3);
                            case 4
                                tform = fitgeotrans(grid_Position_Spline(:,:,iZ),worldPoints,"polynomial", 4);
                        end

                        if(transformationMethod<5)
                            correctedImage=imwarp(LocalrawImage, tform, 'Outputview', RA, 'interp', 'nearest'); %nearest, linear or cubic
                            OutputImage=round(correctedImage,2);
                        else
                            %code for piecewise correction
                            %m,n position in mini maps; i,j positions in world maps
            
                            miniOutputPosition=zeros(9,2);
                            miniGridPosition=zeros(9,2);
            
                            mini_ImageSize=2*squareSize;
                            RA_mini = imref2d([mini_ImageSize mini_ImageSize]);
                
                            miniWorldPoints = generateCheckerboardPoints([4 4], squareSize);
                            miniWorldPoints = flip(miniWorldPoints,2);  %exchange x and y axis in world points
                            
                            iL=floor((app.grid_SizeX-1)/2);
                            jL=floor((app.grid_SizeY-1)/2);
            
                            correctedImage=zeros(mini_ImageSize*jL, mini_ImageSize*iL);
                            grid_Position_Current=grid_Position_Spline(:,:,iZ);
                            
                            for j=1:jL
                                for i=1:iL
                                    i_current=1+(i-1)*2;
                                    j_current=1+(j-1)*2;
                                    for n=1:3
                                        for m=1:3
                                            index_mini=m+(n-1)*3;
                                            index_world=i_current+m-1+(j_current+n-2)*app.grid_SizeX;
                                            miniOutputPosition(index_mini,:)=worldPoints(index_world,:);
                                            miniGridPosition(index_mini,:)=grid_Position_Current(index_world,:);
                                        end
                                    end
                
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
            
                                    correctedminiImage=imwarp(LocalrawImage, tform, 'interp', 'cubic', 'Outputview', RA_mini); %nearest, linear or cubic
                                    correctedImage((xOutput(1)+1):xOutput(2), (yOutput(1)+1):yOutput(2))=correctedminiImage;
                                end
                            end
                            OutputImage=round(correctedImage,2);
                        end
                    else
                        OutputImage=LocalrawImage;
                    end
                    
                    if(app.ui_ApplyDC==true)
                        tMatrix=fitgeotrans(interpolatedPoints(:,:,iZ),DC_ref,'affine');  
                        correctedImage=imwarp(OutputImage, tMatrix, 'Outputview', RA2,'interp', 'nearest'); 
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
            app.grid_PlaneStart=event.Value;
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
                % Each plane's lattice is detected independently (rather than
                % propagated from the previous plane's fitted points), so a
                % bad fit on one plane cannot corrupt every later plane.
                [latticeModel, autoStatus] = GridAutoDetectLattice(app, app.ref_Image);
                if autoStatus < 0
                    latticeModel = app.grid_LatticeModel{i-1};
                    warnState = warning('off','backtrace'); % keep the message, drop the noisy call-stack lines
                    warning('GridCorrection:AutoDetectFailed', ...
                        ['Automatic grid detection failed on plane %d; reusing plane %d''s ' ...
                         'lattice. Please visually re-check this plane.'], i, i-1);
                    warning(warnState);
                else
                    GridLog(app, 'Plane %d: lattice detected (d1=%.2f d2=%.2f, rotation %.1f/%.1fdeg, confidence=%d)', ...
                        i, latticeModel.d1, latticeModel.d2, latticeModel.theta1, latticeModel.theta2, latticeModel.confidence);
                    % Guard against a whole-plane "off by N grid periods"
                    % phase error (e.g. a defocused/low-contrast plane
                    % locking onto the wrong grid line) before it gets
                    % baked into every crossing on this plane.
                    latticeModel = GridAlignPlanePhase(app, i, latticeModel);
                end
                app.grid_LatticeModel{i} = latticeModel;
                GridCheckPlaneContinuity(app, i);

                if app.ui_OptimizeGrid
                    % Only a LIGHT pass here -- just enough to get one
                    % real per-point measurement to feed the cross-plane
                    % (Z) correlation step below. Fully converging every
                    % plane up front (as before) was often wasted effort:
                    % Z-correlation can still decide a plane/point wasn't
                    % trustworthy and replace it with the cross-plane
                    % trend regardless, and every plane gets a second,
                    % thorough refinement pass (seeded from the
                    % corrected positions) after correlation anyway --
                    % seed from each point's own trusted history across
                    % previous planes when available (converges faster,
                    % more robust under weak signal), falling back to
                    % this plane's fresh independent FFT detection for
                    % any point without enough history yet.
                    seedModel = GridLatticeFromZHistory(app, i, latticeModel);
                    GridOptimizePlaneUntilConverged(app, i, seedModel, 1);
                else
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

        end

        % Callback function
        function PiecewiseCorrectionTestButtonPushed(app, event)

            ChangeRefImagePlane(app);
            
            grid_Position_Current=app.grid_Position(:,:,app.grid_PlaneCurrent);
            squareSize = norm(grid_Position_Current(1,:)-grid_Position_Current(app.grid_SizeX,:))/(app.grid_SizeX-1);
            squareSize = ceil(squareSize);
            worldPoints = generateCheckerboardPoints([app.grid_SizeX+1 app.grid_SizeY+1], squareSize);
            worldPoints = flip(worldPoints,2);  %exchange x and y axis in world points
            
            %yWorldLimits = [0 (app.grid_SizeY-1)*squareSize];
            %xWorldLimits = [0 (app.grid_SizeX-1)*squareSize];
            %RA = imref2d([(app.grid_SizeX-1)*squareSize (app.grid_SizeY-1)*squareSize],xWorldLimits,yWorldLimits);

            %code for piecewise correction
            %m,n position in mini maps; i,j positions in world maps
            miniOutputPosition=zeros(9,2);
            miniGridPosition=zeros(9,2);

            miniWorldPoints = generateCheckerboardPoints([4 4], squareSize);
            miniWorldPoints = flip(miniWorldPoints,2);  %exchange x and y axis in world points

            iL=floor(app.grid_SizeX/2);
            jL=floor(app.grid_SizeY/2);


            for j=1:jL
                for i=1:iL
                    i_current=1+(i-1)*2;
                    j_current=1+(j-1)*2;
                    for n=1:3
                        for m=1:3
                            index_mini=m+(n-1)*3;
                            index_world=i_current+m-1+(j_current+n-2)*app.grid_SizeX;
                            miniOutputPosition(index_mini,:)=worldPoints(index_world,:);
                            miniGridPosition(index_mini,:)=grid_Position_Current(index_world,:);
                        end
                    end

                    index=i+(j-1)*iL;
                    app.ref_Image=insertText(app.ref_Image, [miniGridPosition(1,1)+10 miniGridPosition(1,2)+10], index, "TextColor","white", "FontSize", 20, 'BoxOpacity',0);
                    app.ref_Image=app.ref_Image(:,:,1);

                    xOutput = [miniOutputPosition(1,2) miniOutputPosition(end,2)];
                    yOutput = [miniOutputPosition(1,1) miniOutputPosition(end,1)];
                    mini_ImageSize=2*squareSize;
                    RA_mini = imref2d([mini_ImageSize mini_ImageSize]);
        
                    tform = fitgeotrans(miniGridPosition,miniWorldPoints,"affine");
                    correctedminiImage=imwarp(app.ref_Image, tform, 'interp', 'cubic', 'Outputview', RA_mini); %nearest, linear or cubic

                    figure(3);
                    subplot(iL, jL, i+(j-1)*iL);
                    imshow(correctedminiImage, [0 3]);

                    ccc((xOutput(1)+1):xOutput(2), (yOutput(1)+1):yOutput(2))=correctedminiImage;
                end
            end


            figure(2);
            subplot(1,2,1);
            imshow(app.ref_Image, [0 3]);
            title('Before Correction');
            subplot(1,2,2);
            imshow(ccc, [0 3]);
            title('After Correction');
            
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
                case 'correctionTest'
                    CorrectionTestButtonPushed(app, []);
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
            end
            if app.ui_GridEditorMode
                PushGridEditorViewModel(app);
            end
        end

        function ok = ConfirmGridReinit(app, actionLabel, warningDetail)
            % Quick Setup and Populate the Rest both re-run detection from
            % scratch on the planes they touch -- silently discarding any
            % adjustments already made there once the grid is at least
            % partly set up. Confirm before proceeding rather than
            % disabling the buttons outright, so a deliberate re-run
            % (e.g. after picking a different reference image) stays
            % possible without a trip back to Reset Settings.
            if app.grid_SettingStatus < 3
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
                '  .computed { color: var(--text-secondary); }'
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
                '        <label>End slide<span class="hint">computed automatically</span></label>'
                '        <span class="computed" id="gridPlaneEnd">&mdash;</span>'
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
                '    document.getElementById("gridPlaneEnd").innerText = model.gridPlaneEnd;'
                ''
                '    document.getElementById("verboseOutput").checked = !!model.verboseOutput;'
                '    document.getElementById("optimizeGrid").checked = !!model.optimizeGrid;'
                '    document.getElementById("showFittingFigure").checked = !!model.showFittingFigure;'
                '    document.getElementById("transformationMethod").value = model.transformationMethod;'
                '    setIfNotFocused(document.getElementById("outputShiftX"), model.outputShiftX);'
                '    setIfNotFocused(document.getElementById("outputShiftY"), model.outputShiftY);'
                ''
                '    var gridInputs = ["gridSizeX", "gridSizeY", "gridSizeZ", "gridPlaneStart", "gridPlaneAveraging", "gridPlaneInterval"];'
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
                '  [hidden] { display: none !important; }'
                '</style>'
                '</head>'
                '<body>'
                ''
                '<div class="content">'
                '  <button class="back-btn" onclick="sendAction(''backToDashboard'')">&larr; Back to Grid Setup</button>'
                '  <div class="title">Grid Editor</div>'
                ''
                '  <div class="plane-label" id="planeLabel">Plane 1 / 1</div>'
                '  <div id="navRow" class="nav-row">'
                '    <button class="btn secondary nav" id="navFirst" onclick="sendAction(''first'')">|&lt; First</button>'
                '    <button class="btn secondary nav" id="navPrev" onclick="sendAction(''prev'')">&lt; Prev</button>'
                '    <button class="btn secondary nav" id="navNext" onclick="sendAction(''next'')">Next &gt;</button>'
                '    <button class="btn secondary nav" id="navLast" onclick="sendAction(''last'')">Last &gt;|</button>'
                '  </div>'
                ''
                '  <div class="card">'
                '    <h3>Instructions</h3>'
                '    <p class="instructions-text" id="instructionsText"></p>'
                '    <p class="origin-info" id="originInfo" hidden></p>'
                '  </div>'
                ''
                '  <div class="card" id="legendCard">'
                '    <h3>Point Colors</h3>'
                '    <div class="legend-row"><span class="legend-dot" style="background:rgb(0,114,189)"></span><span class="legend-label">Measured (converged)</span></div>'
                '    <div class="legend-row"><span class="legend-dot" style="background:rgb(255,140,191)"></span><span class="legend-label">Outlier (surface-corrected)</span></div>'
                '    <div class="legend-row"><span class="legend-dot" style="background:rgb(255,51,191)"></span><span class="legend-label">Unrefined / no fit</span></div>'
                '    <div class="legend-row"><span class="legend-dot" style="background:rgb(51,204,255)"></span><span class="legend-label">Filled from other planes (Z)</span></div>'
                '  </div>'
                ''
                '  <p class="section-label" id="adjustLabel">Review &amp; adjust this plane (optional)</p>'
                '  <button class="btn secondary action-btn" id="btnAdjustOrigin" onclick="sendAction(''adjustOrigin'')">Adjust Grid Origin</button>'
                '  <button class="btn secondary action-btn" id="btnOptimizePlane" onclick="sendAction(''optimizePlane'')">Optimize This Plane</button>'
                '  <button class="btn secondary action-btn" id="btnCorrectionTest" onclick="sendAction(''correctionTest'')">Correction Test</button>'
                ''
                '  <div class="divider" id="populateDivider"></div>'
                ''
                '  <button class="btn action-btn" id="btnPopulateRest" onclick="sendAction(''populateRest'')">Populate the Rest&hellip;</button>'
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
                '    document.getElementById("btnCorrectionTest").hidden = originMode;'
                '    document.getElementById("btnOptimizePlane").hidden = originMode;'
                '    document.getElementById("populateDivider").hidden = originMode;'
                '    document.getElementById("btnPopulateRest").hidden = originMode;'
                '    document.getElementById("btnFinish").hidden = originMode || !model.allPlanesReady;'
                ''
                '    document.getElementById("btnAdjustOrigin").innerText = originMode ? "Confirm Origin" : "Adjust Grid Origin";'
                ''
                '    var nav = model.nav || {};'
                '    document.getElementById("navFirst").disabled = !nav.first;'
                '    document.getElementById("navPrev").disabled = !nav.prev;'
                '    document.getElementById("navNext").disabled = !nav.next;'
                '    document.getElementById("navLast").disabled = !nav.last;'
                '    document.getElementById("btnCorrectionTest").disabled = !nav.correctionTest;'
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
        function app = ImagePostProcessingDlgV6(varargin)

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