package cz.cuni.mff.cgg.teichmaa.chaosultra.rendering;

import com.jogamp.opengl.GL2;
import com.jogamp.opengl.GLAutoDrawable;
import com.jogamp.opengl.awt.GLCanvas;
import cz.cuni.mff.cgg.teichmaa.chaosultra.cudarenderer.CudaFractalRendererProvider;
import cz.cuni.mff.cgg.teichmaa.chaosultra.rendering.model.GLParams;
import cz.cuni.mff.cgg.teichmaa.chaosultra.rendering.model.GLTexture;
import cz.cuni.mff.cgg.teichmaa.chaosultra.rendering.model.GLTextureHandle;
import cz.cuni.mff.cgg.teichmaa.chaosultra.util.ImageHelpers;
import cz.cuni.mff.cgg.teichmaa.chaosultra.util.JavaHelpers;

import javax.swing.*;
import java.nio.Buffer;
import java.nio.IntBuffer;
import java.util.ArrayList;
import java.util.List;
import java.util.function.Consumer;

import static com.jogamp.opengl.GL.*;
import static cz.cuni.mff.cgg.teichmaa.chaosultra.rendering.FractalRenderer.SUPER_SAMPLING_MAX_LEVEL;

class GLRenderer implements GLView {

    private static final String DEFAULT_COLOR_PALETTE_LOCATION = "palette.png";
    private static final String COLOR_PALETTE_PATH_PROPERTY_NAME = "colorPalette";

    private GLTexture outputTexture;
    private GLTexture paletteTexture;
    private FractalRenderer fractalRenderer = new FractalRendererNullObjectVerbose();
    private FractalRendererProvider fractalRendererProvider;
    private final List<Consumer<GL2>> doBeforeDisplay = new ArrayList<>();
    private boolean doNotRenderRequested = false;
    private final Model model;
    private final RenderingStateModel stateModel;
    private final RenderingController controller;
    private final GLCanvas target;

    public GLRenderer(RenderingController controller, Model model, RenderingStateModel stateModel, GLCanvas target) {
        this.controller = controller;
        this.model = model;
        this.target = target;
        this.stateModel = stateModel;
        model.setCanvasWidth(target.getWidth());
        model.setCanvasHeight(target.getHeight());
    }

    @Override
    public void init(GLAutoDrawable drawable) {
        try {
            assert SwingUtilities.isEventDispatchThread();
            final GL2 gl = drawable.getGL().getGL2();

            //documentation for GL texture handling and lifecycle: https://www.khronos.org/opengl/wiki/Texture_Storage#Direct_creation
            int[] GLHandles = new int[2];
            gl.glGenTextures(GLHandles.length, GLHandles, 0);

            outputTexture = GLTexture.of(
                    GLTextureHandle.of(GLHandles[0]),
                    GL_TEXTURE_2D,
                    0,
                    0
            );

            String colorPalettePath = System.getProperty(COLOR_PALETTE_PATH_PROPERTY_NAME, DEFAULT_COLOR_PALETTE_LOCATION);
            Buffer colorPalette = IntBuffer.wrap(ImageHelpers.loadColorPaletteOrDefault(colorPalettePath));
            paletteTexture = GLTexture.of(
                    GLTextureHandle.of(GLHandles[1]),
                    GL_TEXTURE_2D,
                    colorPalette.limit(),
                    1
            );
            GLHelpers.specifyTextureSizeAndData(gl, paletteTexture, colorPalette);

            fractalRendererProvider = new CudaFractalRendererProvider();
            model.setAvailableFractals(fractalRendererProvider.getAvailableFractals());

            // This call can produce an exception.
            // However, fractalRenderer uses the null-object pattern, so even if not initialized properly to CudaFractalRenderer, we can still call its methods.
            fractalRenderer = fractalRendererProvider.getDefaultRenderer();
            model.setFractalName(fractalRenderer.getFractalName());

            controller.showDefaultView();
        } catch (Exception e) {
            model.logError(e.getMessage());
            if(JavaHelpers.isDebugMode()) throw e;
        }
    }

    @Override
    public void dispose(GLAutoDrawable drawable) {
        assert SwingUtilities.isEventDispatchThread();
        if (fractalRenderer == null) return;
        fractalRenderer.close();

        final GL2 gl = drawable.getGL().getGL2();
        int[] textures = new int[2];
        textures[0] = outputTexture.getHandle().getValue();
        textures[1] = paletteTexture.getHandle().getValue();
        gl.glDeleteTextures(textures.length, textures, 0);
    }

    @Override
    public void display(GLAutoDrawable drawable) {
        try {
            assert SwingUtilities.isEventDispatchThread();
            assert model.getCanvasWidth() == outputTexture.getWidth();
            assert model.getCanvasHeight() == outputTexture.getHeight();
            if (model.getCanvasWidth() == 0 || model.getCanvasHeight() == 0) {
                System.err.printf("Warning, RenderingController.display() called with width=%d, height=%d. Skipping the operation.\n", model.getCanvasWidth(), model.getCanvasHeight()); //todo make a logger for this
                return;
            }

            final GL2 gl = drawable.getGL().getGL2();
            try {
                doBeforeDisplay.forEach(c -> c.accept(gl));
            } finally {
                doBeforeDisplay.clear(); //do not repeat the functions if there has been an exception
            }
            if (doNotRenderRequested) {
                doNotRenderRequested = false;
                return;
            }

            long startTime = System.currentTimeMillis();

            //todo tohle cele by asi ocenilo lepsi navrh. Inspiruj se u her a u Update smycky atd
            //  ve finale by kernel launch asi mohl nebyt blocking
            //      trivialni napad: double buffering, GL vzdy vykresli tu druhou, nez cuda zrovna pocita

            if (stateModel.isZooming()) {
                controller.zoomAt(model.getLastMousePosition(), stateModel.getZoomingDirection());
            }

            render(drawable.getGL().getGL2());

            long endTime = System.currentTimeMillis();
            lastFrameRenderTime = (int) (endTime - startTime);
            //lastFramesRenderTime.get(currentMode.getCurrent()).add((int) (endTime - startTime));
//            System.out.println("" + lastFrameRenderTime + " ms (frame total render time)");
            controller.onRenderingDone();
        } catch (Exception e) {
            model.logError(e.getMessage());
            if(JavaHelpers.isDebugMode()) throw e;
        }
    }

    private static final int shortestFrameRenderTime = 15;
    private static final int maxFrameRenderTime = 1000;
    private static final int lastFramesRenderTimeBufferLength = 2;
    //private Map<RenderingModeFSM.RenderingMode, CyclicBuffer> lastFramesRenderTime = new HashMap<>();
    private int lastFrameRenderTime = shortestFrameRenderTime;

    private void determineRenderingModeQuality() {
        assert SwingUtilities.isEventDispatchThread();
        if (!model.isUseAutomaticQuality()) return;
        if (stateModel.isWaiting() && stateModel.wasProgressiveRendering()) {
            model.setMaxSuperSampling(10); //todo lol proc zrovna deset, kde se to vzalo?
            //aha, uz to chapu, tohle je pro to, aby se mi to po HQ nesekalo a vratilo se to zpatky na neco rychleho (?? default??)
            return;
        }

        //System.out.println("currentMode = " + currentMode);
        if (model.isZooming()) {
            setParamsToBeRenderedIn(shortestFrameRenderTime);
        } else if (stateModel.isMoving()) {
            setParamsToBeRenderedIn(shortestFrameRenderTime);
        } else if (stateModel.isWaiting()) {
            setParamsToBeRenderedIn(shortestFrameRenderTime * 2);
        } else if (stateModel.isProgressiveRendering()) {
            int desiredFrameRenderTime = shortestFrameRenderTime * 2 << stateModel.getProgressiveRenderingLevel(); //exponentially increasing the desired render time
            if (desiredFrameRenderTime > maxFrameRenderTime)
                stateModel.resetState(); //if this is the maximal quality that we want to achieve, stop progressive rendering
            else
                setParamsToBeRenderedIn(desiredFrameRenderTime);
            //pridat sem currentMode.getHighQualityIteration()
            //   a do RenderingMode::step dat highQIteration++
            if (model.getMaxSuperSampling() == SUPER_SAMPLING_MAX_LEVEL)
                stateModel.resetState();
        }

    }

    private void setParamsToBeRenderedIn(int ms) {
        //debug:
//        System.out.print(currentMode + ": ");
//        CyclicBuffer b = lastFramesRenderTime.get(currentMode.getCurrent());
//        for (int i = 0; i < lastFramesRenderTimeBufferLength; i++) {
//            System.out.print(b.get(i) + "\t");
//        }
//        System.out.println();

        //TODO tahle funkce potrebuje jeste hodne dotahnout

        //int mean = Math.round(lastFramesRenderTime.get(currentMode.getCurrent()).getMeanValue());
        int newSS = Math.round(model.getMaxSuperSampling() * ms / (float) Math.max(1, lastFrameRenderTime));
        newSS = Math.max(1, Math.min(newSS, SUPER_SAMPLING_MAX_LEVEL));
        model.setMaxSuperSampling(newSS);
    }

    private void render(final GL2 gl) {
        determineRenderingModeQuality();

        model.setZooming(stateModel.isZooming());

        if (stateModel.wasProgressiveRendering()) {
            fractalRenderer.renderQuality(model);
        } else {
            fractalRenderer.renderFast(model);
        }

        GLHelpers.drawRectangle(gl, outputTexture);
    }

    @Override
    public void reshape(GLAutoDrawable drawable, int x, int y, int width, int height) {
        try {
            final GL2 gl = drawable.getGL().getGL2();
            final int oldHeight = model.getCanvasHeight();
            model.setCanvasWidth(width);
            model.setCanvasHeight(height);
            model.setPlaneSegmentFromCenter(
                    model.getPlaneSegment().getCenterX(),
                    model.getPlaneSegment().getCenterY(),
                    model.getPlaneSegment().getZoom() * height / (double) oldHeight);
            if (oldHeight == 0) { //this happens during program initialization
                controller.showDefaultView(); //reinitialize current fractal
                fractalRenderer.supplyDefaultValues(model);
                fractalRenderer.setFractalCustomParams(model.getFractalCustomParams());
            }

            if (fractalRenderer.getState() == FractalRendererState.readyToRender)
                fractalRenderer.freeRenderingResources();
            outputTexture = outputTexture.withNewSize(width, height);
            GLHelpers.specifyTextureSize(gl, outputTexture);
            fractalRenderer.initializeRendering(GLParams.of(outputTexture, paletteTexture));

            controller.startProgressiveRenderingAsync();
        } catch (Exception e) {
            model.logError(e.getMessage());
            if(JavaHelpers.isDebugMode()) throw e;
        }
    }

    @Override
    public void saveImageAsync(String fileName, String format) {
        assert SwingUtilities.isEventDispatchThread();
        doBeforeDisplay.add(gl -> {
            int width_t = model.getCanvasWidth();
            int height_t = model.getCanvasHeight();
            int[] data = new int[width_t * height_t];
            Buffer b = IntBuffer.wrap(data);
            gl.glBindTexture(GL_TEXTURE_2D, outputTexture.getHandle().getValue());
            {
                //documentation: https://www.khronos.org/registry/OpenGL-Refpages/gl4/html/glGetTexImage.xhtml
                gl.glGetTexImage(GL_TEXTURE_2D, 0, GL_RGBA, GL_UNSIGNED_BYTE, b);
            }
            gl.glBindTexture(GL_TEXTURE_2D, 0);
            ImageHelpers.saveImageToFile(data, width_t, height_t, fileName, format);
            System.out.println("Image saved to " + fileName);
            doNotRenderRequested = true;
        });
        repaint();
    }

    @Override
    public void onFractalCustomParamsUpdated() {
        try {
            fractalRenderer.setFractalCustomParams(model.getFractalCustomParams());
            model.setSampleReuseCacheDirty(true);
        } catch (Exception e){
            model.logError(e.getMessage());
            if(JavaHelpers.isDebugMode()) throw e;
        }
    }

    @Override
    public void repaint() {
        target.repaint();
    }

    @Override
    public void onFractalChanged(String fractalName, boolean forceReload) {
        doBeforeDisplay.add(gl -> {
            if (fractalRenderer.getState() == FractalRendererState.readyToRender)
                fractalRenderer.freeRenderingResources();
            fractalRenderer = fractalRendererProvider.getRenderer(fractalName, forceReload);
            fractalRenderer.supplyDefaultValues(model);
            fractalRenderer.setFractalCustomParams(model.getFractalCustomParams());
            fractalRenderer.initializeRendering(GLParams.of(outputTexture, paletteTexture));
            controller.showDefaultView();
        });
    }

    @Override
    public void debugRightBottomPixel() {
        fractalRenderer.debugRightBottomPixel();
    }

    @Override
    public void launchDebugKernel() {
        fractalRenderer.launchDebugKernel();
    }

    @Override
    public void showDefaultView() {
        fractalRenderer.supplyDefaultValues(model);
        fractalRenderer.setFractalCustomParams(model.getFractalCustomParams());
        repaint();
    }
}
