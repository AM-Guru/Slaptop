(() => {
  "use strict";

  const preventViewportGesture = (event) => event.preventDefault();
  const preventMultiTouch = (event) => {
    if (event.touches && event.touches.length > 1) event.preventDefault();
  };
  const nonPassive = { passive: false };

  document.addEventListener("touchstart", preventMultiTouch, nonPassive);
  document.addEventListener("touchmove", preventMultiTouch, nonPassive);
  document.addEventListener("gesturestart", preventViewportGesture, nonPassive);
  document.addEventListener("gesturechange", preventViewportGesture, nonPassive);
  document.addEventListener("gestureend", preventViewportGesture, nonPassive);

  const SPACE_COUNT = 9;
  const MOVE_DURATION_MS = 940;
  const MISSION_DURATION_MS = 900;
  const AUTOPLAY_DELAY_MS = 2300;
  const MANUAL_PAUSE_MS = 5000;
  const ASSET_VERSION = "20260718-4";

  const canvas = document.querySelector("#tap-demo");
  const captionNode = document.querySelector("#demo-caption");
  const phaseMeter = document.querySelector("#phase-meter-fill");
  const paginationNode = document.querySelector("#space-pagination");
  const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
  const controlButtons = Array.from(document.querySelectorAll(".demo-control[data-tap-side]"));
  const screenButtons = Array.from(document.querySelectorAll(".screen-tap-zone[data-screen-tap]"));

  document.querySelectorAll(".reveal").forEach((element) => element.classList.add("is-visible"));

  function initializeKineticTicker() {
    const strip = document.querySelector(".kinetic-strip");
    const track = strip?.querySelector(".kinetic-track");
    const firstSegment = track?.firstElementChild;
    if (!strip || !track || !firstSegment) return;

    const segmentTemplate = firstSegment.cloneNode(true);
    const pixelsPerMillisecond = 0.064;
    let offset = 0;
    let lastTimestamp = performance.now();
    let animationFrame = 0;

    track.classList.add("is-managed");

    function appendSegment() {
      track.append(segmentTemplate.cloneNode(true));
    }

    function fillRunway() {
      const viewportWidth = Math.max(strip.clientWidth, 1);
      const runwayWidth = viewportWidth * 2;
      let attempts = 0;

      while (track.scrollWidth - offset < runwayWidth && attempts < 100) {
        appendSegment();
        attempts += 1;
      }
    }

    function pruneExpiredSegments() {
      while (track.children.length > 2) {
        const expiredSegment = track.firstElementChild;
        const expiredWidth = expiredSegment?.getBoundingClientRect().width || 0;
        if (!expiredWidth || offset < expiredWidth) break;
        offset -= expiredWidth;
        expiredSegment.remove();
      }
    }

    function positionTrack() {
      track.style.transform = `translate3d(${-offset}px, 0, 0)`;
    }

    function animate(timestamp) {
      const elapsed = Math.min(Math.max(timestamp - lastTimestamp, 0), 64);
      lastTimestamp = timestamp;
      offset += elapsed * pixelsPerMillisecond;
      pruneExpiredSegments();
      fillRunway();
      positionTrack();
      animationFrame = requestAnimationFrame(animate);
    }

    function updateMotionPreference() {
      cancelAnimationFrame(animationFrame);
      lastTimestamp = performance.now();
      fillRunway();
      positionTrack();
      if (!reducedMotion.matches) animationFrame = requestAnimationFrame(animate);
    }

    if ("ResizeObserver" in window) {
      new ResizeObserver(() => {
        fillRunway();
        positionTrack();
      }).observe(strip);
    } else {
      window.addEventListener("resize", () => {
        fillRunway();
        positionTrack();
      });
    }

    if (document.fonts?.ready) document.fonts.ready.then(fillRunway);
    if ("addEventListener" in reducedMotion) {
      reducedMotion.addEventListener("change", updateMotionPreference);
    } else {
      reducedMotion.addListener(updateMotionPreference);
    }

    updateMotionPreference();
  }

  initializeKineticTicker();

  if (!canvas || !captionNode || !phaseMeter || !paginationNode) return;

  const context = canvas.getContext("2d");
  if (!context) {
    canvas.hidden = true;
    screenButtons.forEach((button) => { button.hidden = true; });
    const fallback = document.querySelector(".demo-fallback");
    if (fallback) fallback.style.display = "block";
    return;
  }

  const palettes = [
    { start: "#154bd8", end: "#071d62", accent: "#75a6ff" },
    { start: "#7d38ef", end: "#27116e", accent: "#c09cff" },
    { start: "#ff6a2b", end: "#7b180d", accent: "#ffb07f" },
    { start: "#29c9e6", end: "#0a5678", accent: "#9df2ff" },
    { start: "#8d68ff", end: "#24114f", accent: "#c8ff2f" },
    { start: "#ec2896", end: "#670d54", accent: "#ff9bd4" },
    { start: "#18b8a8", end: "#074f52", accent: "#85fff3" },
    { start: "#e99320", end: "#6c3005", accent: "#ffd07b" },
    { start: "#327df4", end: "#081d55", accent: "#8ec5ff" },
  ];

  function loadImage(source) {
    const image = new Image();
    image.decoding = "async";
    image.src = `${source}?v=${ASSET_VERSION}`;
    return image;
  }

  const handImages = {
    left: loadImage("hand-point-right.png"),
    right: loadImage("hand-point-left.png"),
    top: loadImage("hand-point-down.png"),
  };
  const missionControlImage = loadImage("mission-control.webp");

  let cssWidth = 0;
  let cssHeight = 0;
  let currentSpace = 4;
  let activeTransition = null;
  let missionControlVisible = false;
  let autoDirection = 1;
  let nextAutoplayAt = performance.now() + 1300;
  let lastCaption = "";
  let buttonResetTimer = 0;
  let screenRect = null;

  const paginationDots = Array.from({ length: SPACE_COUNT }, () => {
    const dot = document.createElement("i");
    paginationNode.append(dot);
    return dot;
  });

  function clamp(value, minimum = 0, maximum = 1) {
    return Math.min(Math.max(value, minimum), maximum);
  }

  function ease(value) {
    const clamped = clamp(value);
    return clamped * clamped * (3 - 2 * clamped);
  }

  function roundedRect(ctx, x, y, width, height, radius) {
    const r = Math.min(radius, width / 2, height / 2);
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.arcTo(x + width, y, x + width, y + height, r);
    ctx.arcTo(x + width, y + height, x, y + height, r);
    ctx.arcTo(x, y + height, x, y, r);
    ctx.arcTo(x, y, x + width, y, r);
    ctx.closePath();
  }

  function calculateScreenRect() {
    const width = Math.min(cssWidth * 0.57, 650);
    const height = Math.min(width * 0.62, cssHeight * 0.62);
    return {
      x: (cssWidth - width) / 2,
      y: Math.max(48, (cssHeight - height) * 0.42),
      width,
      height,
    };
  }

  function positionScreenButtons(screen) {
    const leftButton = screenButtons.find((button) => button.dataset.screenTap === "left");
    const rightButton = screenButtons.find((button) => button.dataset.screenTap === "right");
    const topButton = screenButtons.find((button) => button.dataset.screenTap === "top");

    if (leftButton) {
      leftButton.style.left = `${screen.x}px`;
      leftButton.style.top = `${screen.y}px`;
      leftButton.style.width = `${screen.width / 2}px`;
      leftButton.style.height = `${screen.height}px`;
    }
    if (rightButton) {
      rightButton.style.left = `${screen.x + screen.width / 2}px`;
      rightButton.style.top = `${screen.y}px`;
      rightButton.style.width = `${screen.width / 2}px`;
      rightButton.style.height = `${screen.height}px`;
    }
    if (topButton) {
      topButton.style.left = `${screen.x + screen.width * 0.22}px`;
      topButton.style.top = `${screen.y}px`;
      topButton.style.width = `${screen.width * 0.56}px`;
      topButton.style.height = `${Math.max(44, screen.height * 0.2)}px`;
    }
  }

  function resizeCanvas() {
    const bounds = canvas.getBoundingClientRect();
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    cssWidth = Math.max(1, Math.round(bounds.width));
    cssHeight = Math.max(1, Math.round(bounds.height));
    canvas.width = Math.round(cssWidth * dpr);
    canvas.height = Math.round(cssHeight * dpr);
    context.setTransform(dpr, 0, 0, dpr, 0, 0);
    screenRect = calculateScreenRect();
    positionScreenButtons(screenRect);
  }

  function drawDesktop(ctx, rect, palette, index) {
    const gradient = ctx.createLinearGradient(rect.x, rect.y, rect.x + rect.width, rect.y + rect.height);
    gradient.addColorStop(0, palette.start);
    gradient.addColorStop(1, palette.end);
    ctx.fillStyle = gradient;
    ctx.fillRect(rect.x, rect.y, rect.width, rect.height);

    ctx.globalAlpha = 0.18;
    ctx.fillStyle = palette.accent;
    ctx.beginPath();
    ctx.arc(rect.x + rect.width * (0.2 + (index % 4) * 0.18), rect.y + rect.height * 0.3, rect.width * 0.24, 0, Math.PI * 2);
    ctx.fill();
    ctx.globalAlpha = 1;

    const windowWidth = rect.width * (index % 3 === 1 ? 0.68 : 0.61);
    const windowHeight = rect.height * (index % 2 === 0 ? 0.58 : 0.64);
    const windowX = rect.x + rect.width * (0.1 + (index % 3) * 0.065);
    const windowY = rect.y + rect.height * (0.14 + (index % 2) * 0.06);

    ctx.fillStyle = "rgba(246,247,241,0.91)";
    roundedRect(ctx, windowX, windowY, windowWidth, windowHeight, 8);
    ctx.fill();

    ctx.fillStyle = "rgba(255,255,255,0.8)";
    roundedRect(ctx, windowX, windowY, windowWidth, 20, 8);
    ctx.fill();

    for (let dot = 0; dot < 3; dot += 1) {
      ctx.beginPath();
      ctx.arc(windowX + 14 + dot * 14, windowY + 10, 3.2, 0, Math.PI * 2);
      ctx.fillStyle = palette.start;
      ctx.fill();
    }

    ctx.fillStyle = `${palette.accent}55`;
    for (let row = 0; row < 4; row += 1) {
      const lineWidth = windowWidth * (row === 1 ? 0.48 : 0.68);
      roundedRect(ctx, windowX + 16, windowY + 38 + row * 18, lineWidth, 5, 3);
      ctx.fill();
    }
  }

  function drawMissionControl(ctx, screen, offsetY, visible) {
    if (!visible) return;
    ctx.save();
    if (missionControlImage.complete && missionControlImage.naturalWidth) {
      const imageRatio = missionControlImage.naturalWidth / missionControlImage.naturalHeight;
      const screenRatio = screen.width / screen.height;
      let sourceX = 0;
      let sourceY = 0;
      let sourceWidth = missionControlImage.naturalWidth;
      let sourceHeight = missionControlImage.naturalHeight;
      if (imageRatio > screenRatio) {
        sourceWidth = missionControlImage.naturalHeight * screenRatio;
        sourceX = (missionControlImage.naturalWidth - sourceWidth) / 2;
      } else {
        sourceHeight = missionControlImage.naturalWidth / screenRatio;
        sourceY = (missionControlImage.naturalHeight - sourceHeight) / 2;
      }
      ctx.drawImage(
        missionControlImage,
        sourceX,
        sourceY,
        sourceWidth,
        sourceHeight,
        screen.x,
        screen.y + offsetY,
        screen.width,
        screen.height,
      );
    } else {
      ctx.fillStyle = "#08090c";
      ctx.fillRect(screen.x, screen.y + offsetY, screen.width, screen.height);
    }
    ctx.restore();
  }

  function drawHand(ctx, screen, progress, side) {
    if (progress == null || progress < 0 || progress > 1) return;
    const image = handImages[side];
    if (!image || !image.complete || !image.naturalWidth) return;

    const approach = progress < 0.46
      ? ease(progress / 0.46)
      : ease((1 - progress) / 0.54);
    const visibility = Math.sin(progress * Math.PI);
    const width = Math.min(screen.width * (side === "top" ? 0.17 : 0.19), side === "top" ? 108 : 122);
    const height = width * (image.naturalHeight / image.naturalWidth);
    let x = 0;
    let y = 0;
    let contactX = screen.x + screen.width / 2;
    let contactY = screen.y;

    if (side === "left") {
      contactX = screen.x;
      contactY = screen.y + screen.height * 0.42;
      x = screen.x - width * (1.18 - approach * 0.3);
      y = contactY - height * 0.5;
    } else if (side === "right") {
      contactX = screen.x + screen.width;
      contactY = screen.y + screen.height * 0.42;
      x = screen.x + screen.width + width * (0.2 - approach * 0.3);
      y = contactY - height * 0.5;
    } else {
      contactX = screen.x + screen.width / 2;
      contactY = screen.y;
      x = contactX - width / 2;
      y = screen.y - height * (1.2 - approach * 0.3);
    }

    ctx.save();
    ctx.globalAlpha = visibility;
    ctx.shadowColor = "rgba(200,255,47,0.32)";
    ctx.shadowBlur = 18;
    ctx.drawImage(image, x, y, width, height);
    ctx.shadowColor = "transparent";

    if (approach > 0.82) {
      const pulse = (approach - 0.82) / 0.18;
      for (let ring = 0; ring < 2; ring += 1) {
        const radius = 7 + ring * 8 + (1 - pulse) * 4;
        ctx.beginPath();
        ctx.arc(contactX, contactY, radius, 0, Math.PI * 2);
        ctx.strokeStyle = `rgba(200,255,47,${0.72 - ring * 0.25})`;
        ctx.lineWidth = 2;
        ctx.stroke();
      }
    }
    ctx.restore();
  }

  function transitionProgress(timestamp) {
    if (!activeTransition) return 0;
    return clamp((timestamp - activeTransition.startedAt) / activeTransition.duration);
  }

  function finishTransition(timestamp) {
    if (!activeTransition || transitionProgress(timestamp) < 1) return;
    const finished = activeTransition;
    if (finished.type === "space") {
      currentSpace = finished.to;
      missionControlVisible = false;
    } else {
      missionControlVisible = finished.showing;
    }
    activeTransition = null;
    setActiveButtons(null);
    if (!finished.manual) nextAutoplayAt = timestamp + AUTOPLAY_DELAY_MS;
  }

  function visualState(timestamp) {
    let position = currentSpace;
    let missionVisible = missionControlVisible;
    let missionOffsetY = 0;
    let handSide = null;
    let handProgress = null;
    let jiggleX = 0;
    let jiggleY = 0;
    let progress = 0;

    if (activeTransition) {
      progress = transitionProgress(timestamp);
      handSide = activeTransition.side;
      handProgress = progress;
      const jiggleDelta = progress - 0.32;
      if (jiggleDelta >= 0 && jiggleDelta < 0.24) {
        const jiggle = Math.sin(jiggleDelta * 58) * (1 - jiggleDelta / 0.24) * 3.2;
        if (activeTransition.side === "top") jiggleY = jiggle;
        else jiggleX = (activeTransition.side === "left" ? 1 : -1) * jiggle;
      }

      if (activeTransition.type === "space") {
        const slide = ease(clamp((progress - 0.18) / 0.7));
        position = activeTransition.from + (activeTransition.to - activeTransition.from) * slide;
        missionVisible = activeTransition.fromMission;
        missionOffsetY = activeTransition.fromMission
          ? -(screenRect?.height || calculateScreenRect().height) * ease(clamp(progress / 0.32))
          : 0;
      } else {
        const motion = ease(clamp((progress - 0.08) / 0.84));
        const screenHeight = screenRect?.height || calculateScreenRect().height;
        missionVisible = true;
        missionOffsetY = activeTransition.showing
          ? -screenHeight * (1 - motion)
          : -screenHeight * motion;
      }
    }

    return { position, missionVisible, missionOffsetY, handSide, handProgress, jiggleX, jiggleY, progress };
  }

  function drawLaptop(timestamp) {
    const ctx = context;
    const visual = visualState(timestamp);
    const screen = screenRect || calculateScreenRect();
    ctx.clearRect(0, 0, cssWidth, cssHeight);

    ctx.save();
    ctx.translate(visual.jiggleX, visual.jiggleY);
    ctx.shadowColor = "rgba(0,0,0,0.55)";
    ctx.shadowBlur = 45;
    ctx.shadowOffsetY = 20;
    ctx.fillStyle = "#e7e6df";
    roundedRect(ctx, screen.x - 10, screen.y - 10, screen.width + 20, screen.height + 20, 17);
    ctx.fill();
    ctx.shadowColor = "transparent";

    ctx.save();
    roundedRect(ctx, screen.x, screen.y, screen.width, screen.height, 10);
    ctx.clip();
    ctx.fillStyle = "#050605";
    ctx.fillRect(screen.x, screen.y, screen.width, screen.height);
    for (let index = 0; index < SPACE_COUNT; index += 1) {
      drawDesktop(
        ctx,
        { ...screen, x: screen.x + (index - visual.position) * screen.width },
        palettes[index],
        index,
      );
    }
    drawMissionControl(ctx, screen, visual.missionOffsetY, visual.missionVisible);
    ctx.restore();
    ctx.restore();

    ctx.beginPath();
    ctx.arc(screen.x + screen.width / 2, screen.y - 5, 2.5, 0, Math.PI * 2);
    ctx.fillStyle = "rgba(9,10,8,0.7)";
    ctx.fill();

    const baseY = screen.y + screen.height + 16;
    const baseLeft = screen.x - 58;
    const baseRight = screen.x + screen.width + 58;
    const baseGradient = ctx.createLinearGradient(baseLeft, baseY, baseRight, baseY);
    baseGradient.addColorStop(0, "#686a65");
    baseGradient.addColorStop(0.5, "#f1efe8");
    baseGradient.addColorStop(1, "#686a65");
    ctx.beginPath();
    ctx.moveTo(baseLeft, baseY);
    ctx.lineTo(baseRight, baseY);
    ctx.quadraticCurveTo(baseRight - 3, baseY + 22, baseRight - 28, baseY + 25);
    ctx.lineTo(baseLeft + 28, baseY + 25);
    ctx.quadraticCurveTo(baseLeft + 3, baseY + 22, baseLeft, baseY);
    ctx.closePath();
    ctx.fillStyle = baseGradient;
    ctx.fill();

    ctx.fillStyle = "rgba(9,10,8,0.5)";
    roundedRect(ctx, cssWidth / 2 - 40, baseY, 80, 5, 3);
    ctx.fill();
    drawHand(ctx, screen, visual.handProgress, visual.handSide);
  }

  function setActiveButtons(side) {
    [...controlButtons, ...screenButtons].forEach((button) => {
      const buttonSide = button.dataset.tapSide || button.dataset.screenTap;
      const active = Boolean(side && buttonSide === side);
      button.classList.toggle("is-triggered", active);
      button.setAttribute("aria-pressed", String(active));
    });
  }

  function flashButton(side) {
    window.clearTimeout(buttonResetTimer);
    setActiveButtons(side);
    buttonResetTimer = window.setTimeout(() => setActiveButtons(null), 620);
  }

  function startSpaceTransition(side, manual, timestamp) {
    const delta = side === "left" ? -1 : 1;
    const target = clamp(currentSpace + delta, 0, SPACE_COUNT - 1);
    if (target === currentSpace) {
      autoDirection = -delta;
      flashButton(side);
      return false;
    }

    activeTransition = {
      type: "space",
      side,
      from: currentSpace,
      to: target,
      fromMission: missionControlVisible,
      manual,
      startedAt: timestamp,
      duration: reducedMotion.matches ? 1 : MOVE_DURATION_MS,
    };
    autoDirection = -delta;
    setActiveButtons(side);
    return true;
  }

  function startMissionTransition(manual, timestamp) {
    activeTransition = {
      type: "mission",
      side: "top",
      showing: !missionControlVisible,
      manual,
      startedAt: timestamp,
      duration: reducedMotion.matches ? 1 : MISSION_DURATION_MS,
    };
    setActiveButtons("top");
  }

  function triggerTap(side, manual = true) {
    const timestamp = performance.now();
    if (manual) nextAutoplayAt = timestamp + MANUAL_PAUSE_MS;
    if (activeTransition) return;
    if (side === "top") startMissionTransition(manual, timestamp);
    else startSpaceTransition(side, manual, timestamp);
    if (reducedMotion.matches) render(timestamp + 2);
  }

  function maybeAutoplay(timestamp) {
    if (reducedMotion.matches || activeTransition || timestamp < nextAutoplayAt) return;
    let delta = autoDirection;
    if (currentSpace + delta < 0 || currentSpace + delta >= SPACE_COUNT) delta *= -1;
    const side = delta === 1 ? "right" : "left";
    startSpaceTransition(side, false, timestamp);
  }

  function updateInterface(timestamp) {
    const visual = visualState(timestamp);
    const shownSpace = clamp(Math.round(visual.position), 0, SPACE_COUNT - 1);
    const caption = `Space ${shownSpace + 1} of ${SPACE_COUNT} · tap any side`;

    if (caption !== lastCaption) {
      captionNode.textContent = caption;
      lastCaption = caption;
    }

    paginationDots.forEach((dot, index) => dot.classList.toggle("is-current", index === shownSpace));
    if (activeTransition) {
      phaseMeter.style.transform = `scaleX(${visual.progress})`;
    } else if (!reducedMotion.matches) {
      const remaining = clamp((nextAutoplayAt - timestamp) / MANUAL_PAUSE_MS);
      phaseMeter.style.transform = `scaleX(${1 - remaining})`;
    } else {
      phaseMeter.style.transform = "scaleX(0)";
    }
  }

  function render(timestamp = performance.now()) {
    finishTransition(timestamp);
    maybeAutoplay(timestamp);
    drawLaptop(timestamp);
    updateInterface(timestamp);
    if (!reducedMotion.matches) requestAnimationFrame(render);
  }

  function pulseControl(button) {
    button.classList.remove("is-clicked");
    void button.offsetWidth;
    button.classList.add("is-clicked");
  }

  function initializeDownloads() {
    const latestReleaseUrl = "https://github.com/AM-Guru/Slaptop/releases/latest";
    const latestReleaseApi = "https://api.github.com/repos/AM-Guru/Slaptop/releases/latest";
    const downloadButtons = Array.from(document.querySelectorAll("[data-latest-dmg]"));
    if (!downloadButtons.length || typeof window.fetch !== "function") return;

    const latestDmgPromise = window.fetch(latestReleaseApi, {
      headers: { Accept: "application/vnd.github+json" },
    })
      .then((response) => {
        if (!response.ok) throw new Error("Latest release unavailable");
        return response.json();
      })
      .then((release) => {
        const asset = Array.isArray(release.assets)
          ? release.assets.find((candidate) => (
              typeof candidate.name === "string" && candidate.name.toLowerCase().endsWith(".dmg")
            ))
          : null;
        return asset && typeof asset.browser_download_url === "string"
          ? asset.browser_download_url
          : latestReleaseUrl;
      })
      .catch(() => latestReleaseUrl);

    downloadButtons.forEach((button) => {
      button.addEventListener("click", async (event) => {
        event.preventDefault();
        button.setAttribute("aria-busy", "true");
        window.location.assign(await latestDmgPromise);
      });
    });

    latestDmgPromise.then((url) => {
      downloadButtons.forEach((button) => {
        button.href = url;
        button.removeAttribute("aria-busy");
      });
    });
  }

  controlButtons.forEach((button) => {
    button.setAttribute("aria-pressed", "false");
    button.addEventListener("click", () => {
      pulseControl(button);
      triggerTap(button.dataset.tapSide);
    });
    button.addEventListener("animationend", (event) => {
      if (event.animationName === "demo-control-click-pulse") {
        button.classList.remove("is-clicked");
      }
    });
  });

  screenButtons.forEach((button) => {
    button.setAttribute("aria-pressed", "false");
    button.addEventListener("click", (event) => {
      event.preventDefault();
      triggerTap(button.dataset.screenTap);
    });
  });

  if ("ResizeObserver" in window) {
    const resizeObserver = new ResizeObserver(() => {
      resizeCanvas();
      if (reducedMotion.matches) render();
    });
    resizeObserver.observe(canvas);
  } else {
    window.addEventListener("resize", () => {
      resizeCanvas();
      if (reducedMotion.matches) render();
    });
  }

  const handleMotionPreference = () => {
    activeTransition = null;
    setActiveButtons(null);
    nextAutoplayAt = performance.now() + AUTOPLAY_DELAY_MS;
    resizeCanvas();
    render();
  };
  if ("addEventListener" in reducedMotion) {
    reducedMotion.addEventListener("change", handleMotionPreference);
  } else {
    reducedMotion.addListener(handleMotionPreference);
  }

  resizeCanvas();
  render();
  try {
    initializeDownloads();
  } catch {
    // The release-page href remains usable even if lookup is unavailable.
  }
})();
