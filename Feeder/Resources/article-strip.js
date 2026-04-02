// Strip feed CSS and scripts from article content.
// Inspired by NetNewsWire's stripStyles() in main.js.
(function() {
  'use strict';

  var content = document.querySelector('.content');
  if (!content) return;

  // Remove all <link rel="stylesheet"> elements within content
  var links = content.querySelectorAll('link[rel="stylesheet"]');
  for (var i = 0; i < links.length; i++) {
    links[i].remove();
  }

  // Remove <style> elements within content
  var styles = content.querySelectorAll('style');
  for (var i = 0; i < styles.length; i++) {
    styles[i].remove();
  }

  // Remove <script> elements within content (security)
  var scripts = content.querySelectorAll('script');
  for (var i = 0; i < scripts.length; i++) {
    scripts[i].remove();
  }

  // Strip inline style attributes that override our styling
  var styled = content.querySelectorAll('[style]');
  var stripProps = [
    'color', 'background', 'background-color', 'background-image',
    'font-family', 'font-size', 'font-weight',
    'width', 'height', 'min-width', 'min-height', 'max-width', 'max-height',
    'position', 'top', 'right', 'bottom', 'left',
    'float', 'clear'
  ];

  for (var i = 0; i < styled.length; i++) {
    var el = styled[i];
    for (var j = 0; j < stripProps.length; j++) {
      el.style.removeProperty(stripProps[j]);
    }
    // Remove the style attribute entirely if empty
    if (!el.getAttribute('style') || el.getAttribute('style').trim() === '') {
      el.removeAttribute('style');
    }
  }

  // Convert relative image src to absolute
  var baseURL = document.querySelector('base');
  if (baseURL) {
    var imgs = content.querySelectorAll('img[src]');
    for (var i = 0; i < imgs.length; i++) {
      var src = imgs[i].getAttribute('src');
      if (src && !src.startsWith('http') && !src.startsWith('data:')) {
        try {
          imgs[i].setAttribute('src', new URL(src, baseURL.href).href);
        } catch(e) {}
      }
    }
  }
})();
