package cz.cuni.mff.cgg.teichmaa.chaos_ultra.view;


import com.jogamp.opengl.*;

import com.jogamp.opengl.awt.GLCanvas;
import javafx.application.Platform;
import javafx.embed.swing.JFXPanel;
import javafx.fxml.FXMLLoader;
import javafx.scene.Parent;
import javafx.scene.Scene;
import jcuda.driver.CUcontext;
import jcuda.driver.CUdevice;
import jcuda.driver.JCudaDriver;

import javax.swing.*;

import java.awt.*;
import java.io.IOException;

import static jcuda.driver.JCudaDriver.*;

public class Main {

    public static void main(String[] args) {
        new SceneBuilder().start();
    }

    public static void testCudaEtc() {

        GL2 gl = GLContext.getCurrentGL().getGL2();

        gl.glBegin(GL2.GL_LINES);
        {
            gl.glVertex3f(0f, 0f, 0);
            gl.glVertex3f(-1f, 1f, 0);
        }
        gl.glEnd();
        gl.glFinish();


        int breakpoint = 0;

        JCudaDriver.setExceptionsEnabled(true);

        cuInit(0);

        CUdevice dev = new CUdevice();
        CUcontext ctx = new CUcontext();
        cuDeviceGet(dev, 0);
        cuCtxCreate(ctx, 0, dev);

        int[] deviceCount = new int[1];
        CUdevice[] devices = new CUdevice[10];
        cuGLGetDevices(deviceCount, devices, 10, 1);

    }

}
