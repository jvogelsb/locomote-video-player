package com.axis.rtspclient {
  import com.axis.ClientEvent;
  import com.axis.NetStreamClient;
  import com.axis.ErrorManager;
  import com.axis.http.auth;
  import com.axis.http.request;
  import com.axis.http.url;
  import com.axis.IClient;
  import com.axis.Logger;
  import com.axis.rtspclient.FLVMux;
  import com.axis.rtspclient.FLVTag;
  import com.axis.rtspclient.FLVSync;
  import com.axis.rtspclient.RTP;
  import com.axis.rtspclient.RTPTiming;
  import com.axis.rtspclient.SDP;

  import flash.events.AsyncErrorEvent;
  import flash.events.Event;
  import flash.events.EventDispatcher;
  import flash.events.IOErrorEvent;
  import flash.events.NetStatusEvent;
  import flash.events.SecurityErrorEvent;
  import flash.media.Video;
  import flash.net.NetConnection;
  import flash.net.NetStream;
  import flash.net.Socket;
  import flash.utils.ByteArray;
  import flash.events.TimerEvent;
  import flash.utils.Timer;

  import mx.utils.StringUtil;

  public class PingRTSPServer extends NetStreamClient {
    [Embed(source = "../../../../VERSION", mimeType = "application/octet-stream")] private var Version:Class;
    private var userAgent:String;

    private static const STATE_INITIAL:uint  = 1 << 0;
    private static const STATE_OPTIONS:uint  = 1 << 1;
    private static const STATE_DESCRIBE:uint = 1 << 2;
    private static const STATE_TEARDOWN:uint = 1 << 8;
    private var state:int = STATE_INITIAL;
    private var handle:IRTSPHandle;

    private var sdp:SDP = new SDP();
    private var evoStream:Boolean = false;
    private var streamBuffer:Array = new Array();
    private var frameByFrame:Boolean = false;

    private var urlParsed:Object;
    private var cSeq:uint = 1;
    private var session:String;
    private var contentBase:String;

    private var methods:Array = [];
    private var data:ByteArray = new ByteArray();
    private var rtpLength:int = -1;
    private var rtpChannel:int = -1;

    private var prevMethod:Function;

    private var authState:String = "none";
    private var authOpts:Object = {};
    private var digestNC:uint = 1;



    private var bcTimer:Timer;
    private var kaTimer:Timer;
    private var connectionBroken:Boolean = false;

    private var nc:NetConnection = null;

    public function PingRTSPServer(urlParsed:Object, handle:IRTSPHandle) {
      this.userAgent = "Locomote " + StringUtil.trim(new Version().toString());
      this.state = STATE_INITIAL;
      this.handle = handle;
      this.urlParsed = urlParsed;

      handle.addEventListener('data', this.onData);
    }

    public function start(options:Object):Boolean {
      this.bcTimer = new Timer(Player.config.connectionTimeout * 1000, 1);
      this.bcTimer.stop(); // Don't start timeout immediately
      this.bcTimer.reset();
      this.bcTimer.addEventListener(TimerEvent.TIMER_COMPLETE, bcTimerHandler);

      this.setKeepAlive(Player.config.keepAlive);

      this.frameByFrame = Player.config.frameByFrame;

      var self:PingRTSPServer = this;
      handle.addEventListener('connected', function():void {
        if (state !== STATE_INITIAL) {
          ErrorManager.dispatchError(805);
          return;
        }
        self.bcTimer.start();

        /* If the handle closes, take care of it */
        handle.addEventListener('closed', self.onClose);

        if (0 === self.methods.length) {
          /* We don't know the options yet. Start with that. */
          sendOptionsReq();
        } else {
          /* Already queried the options (and perhaps got unauthorized on describe) */
          sendDescribeReq();
        }
      });

      nc = new NetConnection();
      nc.connect(null);
      nc.addEventListener(AsyncErrorEvent.ASYNC_ERROR, onAsyncError);
      nc.addEventListener(IOErrorEvent.IO_ERROR, onIOError);
      nc.addEventListener(NetStatusEvent.NET_STATUS, onNetStatusError);
      nc.addEventListener(SecurityErrorEvent.SECURITY_ERROR, onSecurityError);
      this.ns = new NetStream(nc);
      this.setupNetStream();

      handle.connect();
      return true;
    }

    public function stop():Boolean {
      dispatchEvent(new ClientEvent(ClientEvent.STOPPED));  // FIXME - Change to panel not present
      this.ns.dispose();
      bcTimer.stop();

      try {
        sendTeardownReq();
      } catch (e:*) {}

      this.handle.disconnect();

      nc.removeEventListener(AsyncErrorEvent.ASYNC_ERROR, onAsyncError);
      nc.removeEventListener(IOErrorEvent.IO_ERROR, onIOError);
      nc.removeEventListener(NetStatusEvent.NET_STATUS, onNetStatusError);
      nc.removeEventListener(SecurityErrorEvent.SECURITY_ERROR, onSecurityError);

      return true;
    }

     public function setKeepAlive(seconds:Number):Boolean {
      if (seconds !== 0) {
        this.kaTimer = new Timer(seconds * 1000);
      } else if (this.kaTimer) {
        this.kaTimer.stop();
      }
      return true;
    }

    private function onClose(event:Event):void {
      streamEnded = true;
      this.connectionBroken = true;

      bcTimer.stop();
      this.bcTimer.removeEventListener(TimerEvent.TIMER_COMPLETE, bcTimerHandler);

      if (state !== STATE_TEARDOWN) {
        if (this.streamBuffer.length > 0 && this.streamBuffer[this.streamBuffer.length - 1].timestamp - this.ns.time * 1000 < this.ns.bufferTime * 1000) {
          this.ns.bufferTime = 0;
          this.ns.pause();
          this.ns.resume();
        } else if (bufferEmpty && this.streamBuffer.length === 0) {
          this.ns.dispose();
        }
      }
    }

    private function onData(event:Event):void {
        if (0 < data.bytesAvailable) {
            /* Determining byte have already been read. This is a continuation */
        } else {
            /* Read the determining byte */
            handle.readBytes(data, data.position, 1);
        }

        switch (data[0]) {
            case 0x52:
                /* ascii 'R', start of RTSP */
                onRTSPCommand();
                break;

            default:
                ErrorManager.dispatchError(804, [data[0].toString(16)]);
                stop();
                break;
        }
    }

    private function requestReset():void {
        var copy:ByteArray = new ByteArray();
        data.readBytes(copy);
        data.clear();
        copy.readBytes(data);

        rtpLength = -1;
        rtpChannel = -1;
    }

    private function readRequest(oBody:ByteArray):* {
      var parsed:* = request.readHeaders(handle, data);
      if (false === parsed) {
          return false;
      }

      if (401 === parsed.code) {
        /* Unauthorized, change authState and (possibly) try again */
        authOpts = parsed.headers['www-authenticate'];

        if (authOpts.stale && authOpts.stale.toUpperCase() === 'TRUE') {
          requestReset();
          prevMethod();
          return false;
        }

        var newAuthState:String = auth.nextMethod(authState, authOpts);
        if (authState === newAuthState) {
          ErrorManager.dispatchError(parsed.code);
          return false;
        }

        authState = newAuthState;
        state = STATE_INITIAL;
        data = new ByteArray();
        this.sendDescribeReq();
        return false;
      }

      if (isNaN(parsed.code)) {
        ErrorManager.dispatchError(parsed.code);
        return false;
      }

      if (parsed.headers['content-length']) {
        if (data.bytesAvailable < parsed.headers['content-length']) {
          return false;
        }

        /* RTSP commands contain no heavy body, so it's safe to read everything */
        data.readBytes(oBody, 0, parsed.headers['content-length']);
        Logger.log('RTSP IN:', oBody.toString());
      } else {
        Logger.log('RTSP IN:', data.toString());
      }

      requestReset();
      return parsed;
    }

    private function onRTSPCommand():void {
      var parsed:*, body:ByteArray = new ByteArray();
      if (false === (parsed = readRequest(body))) {
        return;
      }

      // We get the 400/454 because of sending the empty RequestParams due to WEB-311 when the state is INITIAL,
      // OPTIONS, or DESCRIBE.
      // Ignore these for now.
      if (200 !== parsed.code && ((400 !== parsed.code && 454 !== parsed.code) || state > STATE_DESCRIBE )) {
        ErrorManager.dispatchError(parsed.code);
        return;
      } else if (parsed.code === 400 || parsed.code === 454) {
        return;
      }

      switch (state) {
      case STATE_INITIAL:
        Logger.log("PingRTSPServer: STATE_INITIAL");

      case STATE_OPTIONS:
        Logger.log("PingRTSPServer: STATE_OPTIONS");
        this.methods = parsed.headers.public.split(/[ ]*,[ ]*/);
        if (parsed.headers['server'] === 'EvoStream Media Server (www.evostream.com)') {
          this.evoStream = true;
        }
        sendDescribeReq();
        break;

      case STATE_DESCRIBE:
        dispatchEvent(new ClientEvent('rtsp_available'));
        close();
        break;

      case STATE_TEARDOWN:
        Logger.log('PingRTSPServer: STATE_TEARDOWN');
        this.bcTimer.stop();
        this.kaTimer.stop();
        this.kaTimer = null;
        this.handle.disconnect();
        break;
      }

      if (0 < data.bytesAvailable) {
        onData(null);
      }
    }

    private function onTeardownCommand():void {
      Logger.log("Received TEAR_DOWN from server. Closing connection...");
      state = STATE_TEARDOWN;
      closeConnection();
      dispatchEvent(new ClientEvent(ClientEvent.TEARDOWN));
    }

    private function getControlURL():String {
      var sessCtrl:String = sdp.getSessionBlock().control;
      var u:String = sessCtrl;
      if (url.isAbsolute(u)) {
        return u;
      } else if (!u || '*' === u) {
        return contentBase;
      } else {
        return contentBase + u; /* If content base is not set, this will be session control only only */
      }

      Logger.log('Can\'t determine control URL from ' +
              'session.control:' + sessionBlock.control + ', and ' +
              'content-base:' + contentBase);
      ErrorManager.dispatchError(824, null, true);
    }

    private function sendOptionsReq():void {
      state = STATE_OPTIONS;
      var req:String =
        "OPTIONS " + urlParsed.full + " RTSP/1.0\r\n" +
        "CSeq: " + (++cSeq) + "\r\n" +
        "User-Agent: " + userAgent + "\r\n" +
        "\r\n";
      Logger.log('RTSP OUT:', req);
      handle.writeUTFBytes(req);

      /* 9/1/15 JV - We are sending an empty GET_PARAMETER call as a workaround to WEB-311(Chrome and IE flash
         players on 64-bit Windows systems won't read data from the socket after sending "OPTIONS" until another
         packet is sent. Send empty GET_PARAMETER to trigger the socket to fire the SOCKET_DATA event.
       */
      sendGetParamReq();
      prevMethod = sendOptionsReq;
    }

    private function sendDescribeReq():void {
      state = STATE_DESCRIBE;
      var u:String = 'rtsp://' + urlParsed.host + urlParsed.urlpath;
      var req:String =
        "DESCRIBE " + u + " RTSP/1.0\r\n" +
        "CSeq: " + (++cSeq) + "\r\n" +
        "User-Agent: " + userAgent + "\r\n" +
        "Accept: application/sdp\r\n" +
        auth.authorizationHeader("DESCRIBE", authState, authOpts, urlParsed, digestNC++) +
        "\r\n";
      handle.writeUTFBytes(req);
      Logger.log('RTSP OUT:', req);

      prevMethod = sendDescribeReq;
    }

    private function sendGetParamReq():void {
      var req:String =
        "GET_PARAMETER " + getControlURL() + " RTSP/1.0\r\n" +
        "CSeq: " + (++cSeq) + "\r\n" +
        "User-Agent: " + userAgent + "\r\n" +
        "Session: " + session + "\r\n" +
        auth.authorizationHeader("GET_PARAMETER", authState, authOpts, urlParsed, digestNC++) +
        "\r\n";
      Logger.log('RTSP OUT:', req);
      handle.writeUTFBytes(req);

      prevMethod = sendGetParamReq;
    }

    private function sendTeardownReq():void {
      state = STATE_TEARDOWN;
      var req:String =
        "TEARDOWN " + getControlURL() + " RTSP/1.0\r\n" +
        "CSeq: " + (++cSeq) + "\r\n" +
        "User-Agent: " + userAgent + "\r\n" +
        "Session: " + session + "\r\n" +
        auth.authorizationHeader("TEARDOWN", authState, authOpts, urlParsed, digestNC++) +
        "\r\n";

      handle.writeUTFBytes(req);
      Logger.log('RTSP OUT:', req);

      prevMethod = sendTeardownReq;
    }

    private function onAsyncError(event:AsyncErrorEvent):void {
      bcTimer.stop();
      ErrorManager.dispatchError(728);
    }

    private function onIOError(event:IOErrorEvent):void {
      bcTimer.stop();
      ErrorManager.dispatchError(729, [event.text]);
    }

    private function onSecurityError(event:SecurityErrorEvent):void {
      bcTimer.stop();
      ErrorManager.dispatchError(730, [event.text]);
    }

    private function onNetStatusError(event:NetStatusEvent):void {
      if (event.info.status === 'error') {
        bcTimer.stop();
      }
    }

    private function bcTimerHandler(e:TimerEvent):void {
      Logger.log("RTSP stream timed out", { bufferEmpty: bufferEmpty, frameBuffer: this.streamBuffer.length, state: currentState });
      connectionBroken = true;
      closeConnection();

      if (evoStream) {
        streamEnded = true;
      }

      /* If the stream has ended don't dispatch error, evo stream doesn't give
       * us any information about when the stream ends so assume this is the
       * proper end of the stream */
      if (!streamEnded) {
        ErrorManager.dispatchError(827);
      }
    }

    private function closeConnection():void {
      this.handle.disconnect();
      bcTimer.stop();
      bcTimer = null;
      this.handle.disconnect();
      this.handle = null;

      nc.removeEventListener(AsyncErrorEvent.ASYNC_ERROR, onAsyncError);
      nc.removeEventListener(IOErrorEvent.IO_ERROR, onIOError);
      nc.removeEventListener(NetStatusEvent.NET_STATUS, onNetStatusError);
      nc.removeEventListener(SecurityErrorEvent.SECURITY_ERROR, onSecurityError);

      if (bufferEmpty && this.streamBuffer.length === 0) {
        dispatchEvent(new ClientEvent(ClientEvent.STOPPED));
        this.ns.dispose();
      }
    }
  }
}
