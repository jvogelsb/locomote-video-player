package com.axis.rtspclient {
  import com.axis.rtspclient.ByteArrayUtils;
  import com.axis.rtspclient.RTP;
  import com.axis.Logger;

  import flash.events.Event;
  import flash.events.EventDispatcher;
  import flash.external.ExternalInterface;
  import flash.utils.ByteArray;

  /* Assembler of PCMU frames */
  public class APCMU extends EventDispatcher {
    private var bufferedData:ByteArray = new ByteArray()
    private var initialRTPTimeStamp:Number = -1;
    public function APCMU() {}

    // Seems with our cameras that as long as the pcmu data is smaller than 1280 bytes, the flash player can play it.
    // When it is 1280+=, the audio starts to get choppy.
    // A smallPktSize(e.g. 20 bytes), seems to affect the video and make it more jittery. 640 bytes seems to work best
    // for our cameras.
    private var smallPktSize:uint = 640;
    private var smallPktTimeMs:uint = Math.round(smallPktSize * (1000/8000));    // in ms

    public function onRTPPacket(pkt:RTP):void {
      var data:ByteArray = pkt.getPayload();
      var pcmuData:ByteArray = new ByteArray();

      if (initialRTPTimeStamp == -1) {
        initialRTPTimeStamp = pkt.getTimestampMS()
      }
      var ts:Number = pkt.getTimestampMS() - initialRTPTimeStamp

      var numPkts:uint =  pkt.bodyLength / smallPktSize;
      for (var i:int = 0; i < numPkts; i++) {
        pcmuData.writeBytes(data, (i * smallPktSize) + data.position, smallPktSize);
        dispatchEvent(new PCMUFrame(pcmuData, ts + (i * smallPktTimeMs)));
        pcmuData.clear()
      }

      // Add any remainging bytes, 620 and 110 cameras have different audio pkt sizes.
      var bytesLeft:uint = pkt.bodyLength - (i*smallPktSize);
      if (bytesLeft > 0) {
        pcmuData.writeBytes(data, (i * smallPktSize) + data.position, bytesLeft);
        dispatchEvent(new PCMUFrame(pcmuData, ts + (i * smallPktTimeMs)));
        pcmuData.clear()
      }
    }
  }
}
